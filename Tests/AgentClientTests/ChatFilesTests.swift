import XCTest
@testable import AgentClient

/// Files of any kind, many at once: raw upload of non-photos, the 20-per-message and
/// 3-at-a-time limits, per-file failures, and names and icons for files.
@MainActor
final class ChatFilesTests: XCTestCase {
    private let attachments = "/studio/api/workspace/threads/t-1/attachments/"

    override func setUp() {
        super.setUp()
        APIClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
        SSEClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
    }

    override func tearDown() {
        MockURLProtocol.reset()
        APIClient.sessionConfigurator = nil
        SSEClient.sessionConfigurator = nil
        super.tearDown()
    }

    private func model() -> ChatViewModel {
        var config = ChatWidgetConfig(backendUrl: "https://studio.example", agentKey: "helper-\(UUID().uuidString)")
        config.authStrategy = .token
        config.authToken = "synthetic-files"
        config.apiPaths.attachments = attachments
        let storage = InMemoryStorage()
        return ChatViewModel(config: config, apiClient: APIClient(config: config, storage: storage), storage: storage)
    }

    func testADocumentUploadsAsItIsWithItsTypeFromTheName() async throws {
        let vm = model()
        MockURLProtocol.register { _ in
            .json(status: 201, body: Data(#"{"id":"f-1","name":"report.pdf","content_type":"application/pdf","size":8}"#.utf8))
        }
        let file = try await vm.uploadFile(data: Data("%PDF-1.4\n".utf8), filename: "report.pdf")
        XCTAssertEqual(file.attachmentId, "f-1")
        XCTAssertEqual(file.type, "application/pdf")
        let body = String(decoding: try XCTUnwrap(MockURLProtocol.recorded.last?.body), as: UTF8.self)
        XCTAssertTrue(body.contains(#"filename="report.pdf""#))
        XCTAssertTrue(body.contains("Content-Type: application/pdf"), body)
        XCTAssertTrue(body.contains("%PDF-1.4"))
    }

    func testAnUnknownExtensionGoesAsOctetStream() {
        XCTAssertEqual(ChatViewModel.contentType(forFilename: "blob.zzzunknown"), "application/octet-stream")
        XCTAssertEqual(ChatViewModel.contentType(forFilename: "noextension"), "application/octet-stream")
    }

    func testAFileOver25MBIsRefusedBeforeUploading() async {
        let vm = model()
        MockURLProtocol.register { _ in .json(status: 201, body: Data(#"{"id":"x"}"#.utf8)) }
        do {
            _ = try await vm.uploadFile(data: Data(count: ChatViewModel.maxFileBytes + 1), filename: "big.bin")
            XCTFail("expected tooLarge")
        } catch let error as AttachmentUploadError {
            XCTAssertEqual(error, .tooLarge)
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
    }

    func testTheHostRefusingAProgramShowsItsReasonAndOnlyThatFileFails() async throws {
        let vm = model()
        MockURLProtocol.register { request in
            let body = String(decoding: MockURLProtocol.bodyData(of: request) ?? Data(), as: UTF8.self)
            if body.contains("setup.exe") {
                return .json(status: 400, body: Data(#"{"file":"Programs can't be attached."}"#.utf8))
            }
            return .json(status: 201, body: Data(#"{"id":"ok","name":"notes.txt","content_type":"text/plain","size":5}"#.utf8))
        }
        async let bad: Result<FileAttachment, Error> = { do { return .success(try await vm.uploadFile(data: Data("MZ....".utf8), filename: "setup.exe")) } catch { return .failure(error) } }()
        async let good: Result<FileAttachment, Error> = { do { return .success(try await vm.uploadFile(data: Data("hello".utf8), filename: "notes.txt")) } catch { return .failure(error) } }()
        let (b, g) = await (bad, good)
        guard case .failure(let error) = b, let upload = error as? AttachmentUploadError else { return XCTFail("expected failure") }
        XCTAssertEqual(upload, .rejected("Programs can't be attached."))
        guard case .success(let file) = g else { return XCTFail("the other file should upload") }
        XCTAssertEqual(file.attachmentId, "ok")
        XCTAssertFalse(vm.attachmentsUnavailable)
    }

    func testTwentyAttachmentsAreSentAndTwentyOneAreNot() async throws {
        XCTAssertEqual(ChatViewModel.maxAttachmentsPerMessage, 20)
        let vm = model()
        MockURLProtocol.register { request in
            guard request.url?.path.hasSuffix("/runs") == true else { return nil }
            return .json(status: 201, body: Data(#"{"id":"run-1","conversation_id":"c-1","status":"succeeded","output":{"final_messages":[{"role":"assistant","content":"Read."}]}}"#.utf8))
        }
        let files = (1...21).map { FileAttachment(name: "f\($0).pdf", size: 1, type: "application/pdf", attachmentId: "a-\($0)") }
        await vm.sendMessage("Look", files: files)
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty, "21 are refused")
        await vm.sendMessage("Look", files: Array(files.prefix(20)))
        let create = try XCTUnwrap(MockURLProtocol.recorded.first { $0.path.hasSuffix("/runs") })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(create.body)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual((messages.last?["attachment_ids"] as? [String])?.count, 20)
    }

    func testTheGateRunsThreeAtATimeAndKeepsOrder() async {
        let gate = UploadGate(limit: 3)
        let tracker = Tracker()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    do { try await gate.acquire() } catch { return }
                    await tracker.start(index)
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await tracker.finish()
                    await gate.release()
                }
            }
        }
        let peak = await tracker.peak
        let started = await tracker.started
        XCTAssertEqual(peak, 3)
        XCTAssertEqual(started.count, 10)
    }

    func testACancelledWaiterLeavesTheLineWithoutTakingAPlace() async throws {
        let gate = UploadGate(limit: 1)
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        do { try await waiter.value; XCTFail("should be cancelled") } catch is CancellationError {}
        await gate.release()
        // The place is free again: this must not wait.
        try await gate.acquire()
        await gate.release()
    }

    func testFilesGetNamesIconsAndSizes() {
        XCTAssertEqual(FileAttachment(name: "a.pdf", size: 0, type: "application/pdf").symbolName, "doc.richtext")
        XCTAssertEqual(FileAttachment(name: "a.xlsx", size: 0, type: "application/octet-stream").symbolName, "tablecells")
        XCTAssertEqual(FileAttachment(name: "a.zip", size: 0, type: "application/zip").symbolName, "doc.zipper")
        XCTAssertEqual(FileAttachment(name: "a", size: 0, type: "application/octet-stream").symbolName, "doc")
        XCTAssertEqual(FileAttachment(name: "a.jpg", size: 0, type: "image/jpeg").symbolName, "photo")
        XCTAssertEqual(FileAttachment(name: "a", size: 0, type: "x").sizeText, "")
        XCTAssertFalse(FileAttachment(name: "a", size: 2_000_000, type: "x").sizeText.isEmpty)
    }

    func testHistoryReadsTheAttachmentListOnceAndFetchesBytesOnlyForImages() async throws {
        let vm = model()
        MockURLProtocol.register { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/attachments") && request.httpMethod == "GET" {
                return .json(status: 200, body: Data("""
                {"attachments":[
                 {"attachment_id":"f-1","name":"plan.docx","size":4096,"content_type":"application/vnd.openxmlformats-officedocument.wordprocessingml.document","created_at":"2026-10-30T10:00:00Z"},
                 {"attachment_id":"p-2","name":"shot.jpg","size":99,"content_type":"image/jpeg","created_at":"2026-10-30T10:00:00Z"}]}
                """.utf8))
            }
            if path.contains("/conversations/") {
                return .json(status: 200, body: Data(#"{"id":"c-1","messages":[{"role":"user","content":"See","id":"m1","seq":1,"metadata":{"attachment_ids":["f-1","p-2"]}},{"role":"user","content":"Again","id":"m2","seq":2,"metadata":{"attachment_ids":["f-1"]}}]}"#.utf8))
            }
            return nil
        }
        _ = await vm.loadConversation("c-1")
        let files = vm.messages.compactMap(\.files).flatMap { $0 }
        XCTAssertEqual(files.map(\.name), ["plan.docx", "shot.jpg", "plan.docx"])
        XCTAssertEqual(files.first?.symbolName, "doc.text")
        XCTAssertEqual(files.first?.isImage, false)
        XCTAssertEqual(files[1].isImage, true)
        XCTAssertEqual(files.first?.size, 4096)
        let lists = MockURLProtocol.recorded.filter { $0.method == "GET" && $0.path.hasSuffix("/attachments") }
        XCTAssertEqual(lists.count, 1, "once per conversation")
        XCTAssertTrue(MockURLProtocol.recorded.filter { $0.path.contains("/attachments/") && $0.method == "GET" }.isEmpty, "no bytes fetched")
    }

    func testAFailedListLeavesPlainAttachmentChipsAndFetchesNoBytes() async {
        let vm = model()
        MockURLProtocol.register { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/attachments") { return .json(status: 500, body: Data("{}".utf8)) }
            if path.contains("/conversations/") {
                return .json(status: 200, body: Data(#"{"id":"c-1","messages":[{"role":"user","content":"See","id":"m1","seq":1,"metadata":{"attachment_ids":["f-1"]}}]}"#.utf8))
            }
            return nil
        }
        _ = await vm.loadConversation("c-1")
        let file = vm.messages.first?.files?.first
        XCTAssertEqual(file?.name, "Attachment")
        XCTAssertEqual(file?.isImage, false)
        XCTAssertTrue(MockURLProtocol.recorded.filter { $0.path.contains("/attachments/") }.isEmpty)
    }

    func testAFailedListIsRetriedOnTheNextLoad() async {
        let vm = model()
        var listCalls = 0
        MockURLProtocol.register { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/attachments") {
                listCalls += 1
                if listCalls == 1 { return .json(status: 500, body: Data("{}".utf8)) }
                return .json(status: 200, body: Data(#"{"attachments":[{"attachment_id":"f-1","name":"a.pdf","size":5,"content_type":"application/pdf"}]}"#.utf8))
            }
            if path.contains("/conversations/") {
                return .json(status: 200, body: Data(#"{"id":"c-1","messages":[{"role":"user","content":"See","id":"m1","seq":1,"metadata":{"attachment_ids":["f-1"]}}]}"#.utf8))
            }
            return nil
        }
        _ = await vm.loadConversation("c-1")
        XCTAssertEqual(vm.messages.first?.files?.first?.name, "Attachment")
        await vm.resolveAttachmentDetails()
        XCTAssertEqual(vm.messages.first?.files?.first?.name, "a.pdf")
        XCTAssertEqual(listCalls, 2)
    }

    func testOlderPagesAreNamedToo() async {
        let vm = model()
        MockURLProtocol.register { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/attachments") {
                return .json(status: 200, body: Data(#"{"attachments":[{"attachment_id":"old-1","name":"old.csv","size":5,"content_type":"text/csv"}]}"#.utf8))
            }
            if path.contains("/conversations/") {
                let before = request.url?.query?.contains("before_seq") == true
                return .json(status: 200, body: Data(before
                    ? #"{"id":"c-1","messages":[{"role":"user","content":"Old","id":"m0","seq":1,"metadata":{"attachment_ids":["old-1"]}}]}"#.utf8
                    : #"{"id":"c-1","has_more":true,"next_before_seq":2,"messages":[{"role":"user","content":"New","id":"m1","seq":2}]}"#.utf8))
            }
            return nil
        }
        _ = await vm.loadConversation("c-1")
        await vm.loadMoreMessages()
        XCTAssertEqual(vm.messages.first?.files?.first?.name, "old.csv")
    }
}

private actor Tracker {
    private(set) var running = 0
    private(set) var peak = 0
    private(set) var started: [Int] = []
    func start(_ index: Int) { running += 1; peak = max(peak, running); started.append(index) }
    func finish() { running -= 1 }
}
