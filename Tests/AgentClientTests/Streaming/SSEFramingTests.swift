import XCTest
@testable import AgentClient

final class SSEFramingTests: XCTestCase {
    func testEveryUTF8AndCRLFSplitPreservesMultilineData() throws {
        let bytes = Data(": heartbeat\r\nevent: assistant.message\r\nid: 7\r\ndata: {\"text\":\r\ndata: \"👩🏽‍💻 café\"}\r\n\r\n".utf8)
        for split in 0...bytes.count {
            var parser = SSEParser()
            let events = try parser.append(Data(bytes.prefix(split))) + parser.append(Data(bytes.dropFirst(split)))
            XCTAssertEqual(events.count, 1, "split=\(split)")
            XCTAssertEqual(events.first?.type, "assistant.message")
            XCTAssertEqual(events.first?.id, "7")
            XCTAssertEqual(events.first?.data, "{\"text\":\n\"👩🏽‍💻 café\"}")
        }
    }

    func testByteAtATimeLFAndCRFramesAndEmptyData() throws {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for byte in Data("data:  keep spaces  \n\ndata:\r\rdata: last\n\n".utf8) {
            events += try parser.append(Data([byte]))
        }
        XCTAssertEqual(events.map(\.data), [" keep spaces  ", "", "last"])
    }

    func testIncompleteFrameIsNotDispatched() throws {
        var parser = SSEParser()
        XCTAssertTrue(try parser.append(Data("data: partial\n".utf8)).isEmpty)
    }

    func testInvalidUTF8IsTypedFailure() {
        var parser = SSEParser()
        XCTAssertThrowsError(try parser.append(Data([0x64, 0x61, 0x74, 0x61, 0x3a, 0xff, 10]))) {
            XCTAssertEqual($0 as? SSEFailure, .invalidUTF8)
        }
    }

    func testLineAndMultilineFrameLimits() {
        var line = SSEParser(maxLineBytes: 8)
        XCTAssertThrowsError(try line.append(Data("data: 123456789".utf8))) {
            XCTAssertEqual($0 as? SSEFailure, .frameTooLarge)
        }
        var frame = SSEParser(maxLineBytes: 20, maxFrameBytes: 20)
        XCTAssertThrowsError(try frame.append(Data("data: one\ndata: two\ndata: three\n\n".utf8))) {
            XCTAssertEqual($0 as? SSEFailure, .frameTooLarge)
        }
        var unfinished = SSEParser(maxLineBytes: 100, maxFrameBytes: 12)
        XCTAssertThrowsError(try unfinished.append(Data("data: a\ndata: unfinished".utf8))) {
            XCTAssertEqual($0 as? SSEFailure, .frameTooLarge)
        }
    }

    func testBOMCommentsIdInheritanceAndNullIdAreHandled() throws {
        var parser = SSEParser()
        let events = try parser.append(Data("\u{FEFF}: comment\nid: 7\ndata: first\n\nid: bad\0id\ndata: second\n\nid:\ndata: third\n\n".utf8))
        XCTAssertEqual(events.map(\.id), ["7", "7", ""])
        XCTAssertEqual(events.map(\.data), ["first", "second", "third"])
    }

    @MainActor
    func testRejectedHTTPAndMimeNeverDispatchBodyAsEvents() async {
        SSEClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
        defer { MockURLProtocol.reset(); SSEClient.sessionConfigurator = nil }
        for (status, mime, expected) in [(401, "text/event-stream", SSEFailure.httpStatus(401)),
                                         (200, "application/json", SSEFailure.invalidContentType)] {
            MockURLProtocol.reset()
            MockURLProtocol.register { _ in .json(status: status, body: Data("data: forbidden\n\n".utf8), headers: ["Content-Type": mime]) }
            let failed = expectation(description: "HTTP validation")
            let client = SSEClient()
            client.onEvent = { _ in XCTFail("Rejected bodies are not event streams") }
            client.onComplete = { XCTFail("Rejection is not completion") }
            client.onError = { error in XCTAssertEqual(error as? SSEFailure, expected); failed.fulfill() }
            client.connect(url: URL(string: "https://example.test/stream")!)
            await fulfillment(of: [failed], timeout: 2)
        }
    }

    func testHTTPValidationAndRetryClassification() {
        let url = URL(string: "https://example.test/stream/")!
        for status in [401, 403, 404, 410, 429, 500] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            XCTAssertEqual(SSEClient.validate(response), .httpStatus(status))
            XCTAssertEqual(SSEFailure.httpStatus(status).isRetryable, status == 429 || status == 500)
        }
        let html = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        XCTAssertEqual(SSEClient.validate(html), .invalidContentType)
        let sse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "Text/Event-Stream; charset=utf-8"])!
        XCTAssertNil(SSEClient.validate(sse))
        XCTAssertGreaterThan(SSEClient.Timeouts().idle, 900)
        XCTAssertGreaterThan(SSEClient.Timeouts().overall, SSEClient.Timeouts().idle)
    }

    @MainActor
    func testEOFIsFailureNotCompletion() async {
        SSEClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
        defer { MockURLProtocol.reset(); SSEClient.sessionConfigurator = nil }
        MockURLProtocol.register { _ in .sse(chunks: [Data(": keepalive\n\n".utf8)]) }
        let failed = expectation(description: "EOF failure")
        let client = SSEClient()
        client.onComplete = { XCTFail("EOF is not completion") }
        client.onError = { error in
            XCTAssertEqual(error as? SSEFailure, .unexpectedEOF)
            failed.fulfill()
        }
        client.connect(url: URL(string: "https://example.test/stream/")!)
        await fulfillment(of: [failed], timeout: 2)
    }

    @MainActor
    func testReplacingConnectionDropsRemainingOldPacketEventsAndEOF() async {
        SSEClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
        defer { MockURLProtocol.reset(); SSEClient.sessionConfigurator = nil }
        MockURLProtocol.register { request in
            let text = request.url?.path == "/old" ? "data: replace\n\ndata: stale\n\n" : "data: new\n\n"
            return .sse(chunks: [Data(text.utf8)])
        }
        let received = expectation(description: "replacement event")
        let client = SSEClient()
        var texts: [String] = []
        client.onError = { _ in XCTFail("old EOF must not close the replacement") }
        client.onEvent = { event in
            texts.append(event.data)
            if event.data == "replace" { client.connect(url: URL(string: "https://example.test/new")!) }
            else { client.disconnect(); received.fulfill() }
        }
        client.connect(url: URL(string: "https://example.test/old")!)
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(texts, ["replace", "new"])
        client.onEvent = nil
    }
}