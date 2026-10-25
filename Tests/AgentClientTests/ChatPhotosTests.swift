import XCTest
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif
@testable import AgentClient

/// Photos with a host attachments URL (`APIPaths.attachments`): uploaded when picked
/// (multipart `file`), sent as `attachment_ids`, read back by id for thumbnails.
/// Without the URL nothing changes.
@MainActor
final class ChatPhotosTests: XCTestCase {
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

    private func model(attachments: String? = "/studio/api/workspace/threads/t-1/attachments/") -> ChatViewModel {
        var config = ChatWidgetConfig(backendUrl: "https://studio.example", agentKey: "helper-\(UUID().uuidString)")
        config.authStrategy = .token
        config.authToken = "synthetic-photos"
        config.apiPaths.attachments = attachments
        let storage = InMemoryStorage()
        return ChatViewModel(config: config, apiClient: APIClient(config: config, storage: storage), storage: storage)
    }

    /// A tiny real PNG (the server and ImageIO both read it).
    private func png(width: Int = 2, height: Int = 2) throws -> Data {
        #if canImport(ImageIO)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
        #else
        throw XCTSkip("ImageIO is needed to make a test PNG")
        #endif
    }

    func testWithoutAnAttachmentsURLPhotosStayOff() {
        XCTAssertFalse(model(attachments: nil).attachmentsEnabled)
        XCTAssertTrue(model().attachmentsEnabled)
    }

    func testUploadPostsOneMultipartFileWithTheTokenAndReturnsTheId() async throws {
        let vm = model()
        var seen: URLRequest?
        MockURLProtocol.register { request in
            seen = request
            return .json(status: 201, body: Data(#"{"id":"a-1","name":"photo.jpg","content_type":"image/jpeg","size":321}"#.utf8))
        }
        let file = try await vm.uploadPhoto(data: try png(), filename: "red.png")
        XCTAssertEqual(file.attachmentId, "a-1")
        XCTAssertEqual(file.type, "image/jpeg")
        XCTAssertEqual(file.size, 321)
        let request = try XCTUnwrap(seen)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://studio.example\(attachments)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token synthetic-photos")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: try XCTUnwrap(MockURLProtocol.recorded.last?.body), as: UTF8.self)
        XCTAssertTrue(body.contains(#"Content-Disposition: form-data; name="file"; filename="red.png""#), body)
        XCTAssertTrue(body.contains("Content-Type: image/png"))
        // A small PNG goes as it is; only large or HEIC photos are re-encoded.
        XCTAssertEqual(body.components(separatedBy: "Content-Disposition:").count - 1, 1, "exactly one form field")
    }

    func testNoStorageOnTheHostTurnsPhotosOff() async throws {
        let vm = model()
        MockURLProtocol.register { _ in
            .json(status: 503, body: Data(#"{"detail":"Photos aren't set up on this Studio.","code":"attachments_unavailable"}"#.utf8))
        }
        do {
            _ = try await vm.uploadPhoto(data: try png(), filename: "red.png")
            XCTFail("expected unavailable")
        } catch let error as AttachmentUploadError {
            XCTAssertEqual(error, .unavailable)
        }
        XCTAssertTrue(vm.attachmentsUnavailable)
        XCTAssertFalse(vm.attachmentsEnabled)
    }

    func testUploadErrorsReadPlainly() async throws {
        let cases: [(Int, String, AttachmentUploadError)] = [
            (413, #"{"detail":"A photo can be at most 20 MB.","code":"too_large"}"#, .tooLarge),
            (400, #"{"file":["Only PNG, JPEG, GIF or WebP photos can be attached."]}"#,
             .rejected("Only PNG, JPEG, GIF or WebP photos can be attached.")),
            (404, #"{}"#, .notAllowed),
        ]
        for (status, body, expected) in cases {
            MockURLProtocol.reset()
            MockURLProtocol.register { _ in .json(status: status, body: Data(body.utf8)) }
            do {
                _ = try await model().uploadPhoto(data: try png(), filename: "red.png")
                XCTFail("expected \(expected)")
            } catch let error as AttachmentUploadError {
                XCTAssertEqual(error, expected)
            }
        }
        XCTAssertEqual(AttachmentUploadError.tooLarge.errorDescription, "This photo is too large.")
    }

    func testAPhotoAloneIsSentAsAttachmentIds() async throws {
        let vm = model()
        MockURLProtocol.register { request in
            guard request.httpMethod == "POST", request.url?.path.hasSuffix("/runs") == true else { return nil }
            return .json(status: 201, body: Data(#"{"id":"run-1","conversation_id":"c-1","status":"succeeded","output":{"final_messages":[{"role":"assistant","content":"A red square."}]}}"#.utf8))
        }
        let photo = FileAttachment(name: "photo.jpg", size: 9, type: "image/jpeg", attachmentId: "a-1")
        await vm.sendMessage("", files: [photo])
        let create = try XCTUnwrap(MockURLProtocol.recorded.first { $0.method == "POST" && $0.path.hasSuffix("/runs") })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(create.body)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["content"] as? String, "")
        XCTAssertEqual(messages.last?["attachment_ids"] as? [String], ["a-1"])
        XCTAssertEqual(vm.messages.first { $0.role == .user }?.files?.first?.attachmentId, "a-1")
    }

    func testMoreThanFourPhotosAreNotSent() async {
        let vm = model()
        let photos = (1...5).map { FileAttachment(name: "p\($0)", size: 1, type: "image/jpeg", attachmentId: "a-\($0)") }
        await vm.sendMessage("Look", files: photos)
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
    }

    func testHistoryCarriesAttachmentIdsInEitherCasing() throws {
        for key in ["attachment_ids", "attachmentIds"] {
            let json = #"{"role":"user","content":"Look","metadata":{"\#(key)":["a-9", 3, ""]}}"#
            let message = try JSONDecoder().decode(APIMessage.self, from: Data(json.utf8))
            XCTAssertEqual(message.metadata?.attachmentIds, ["a-9"])
        }
    }

    func testFetchAttachmentReadsTheIdUnderTheAttachmentsURL() async throws {
        var seen: URLRequest?
        MockURLProtocol.register { request in
            seen = request
            return .json(status: 200, body: Data("jpeg".utf8), headers: ["Content-Type": "image/jpeg"])
        }
        let data = await model().attachmentData(id: "a-1")
        XCTAssertEqual(data, Data("jpeg".utf8))
        XCTAssertEqual(seen?.url?.absoluteString, "https://studio.example\(attachments)a-1/")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Token synthetic-photos")
    }

    func testPhotoTypesAreReadFromTheBytes() throws {
        XCTAssertEqual(PhotoPreparation.sniffType(try png()), "image/png")
        XCTAssertEqual(PhotoPreparation.sniffType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(PhotoPreparation.sniffType(Data("GIF89a......".utf8)), "image/gif")
        XCTAssertEqual(PhotoPreparation.sniffType(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), "image/webp")
        XCTAssertEqual(PhotoPreparation.sniffType(Data("\0\0\0\u{18}ftypheic\0\0\0\0".utf8)), "image/heic")
        XCTAssertNil(PhotoPreparation.sniffType(Data("hello".utf8)))
        XCTAssertNil(PhotoPreparation.prepare(data: Data("hello".utf8), filename: "notes.txt"))
    }

    func testALargePhotoBecomesAJpegWithinTheLimit() throws {
        #if canImport(ImageIO)
        let small = try png(width: 40, height: 10)
        XCTAssertEqual(PhotoPreparation.prepare(data: small, filename: "s.png")?.data, small, "within limits: unchanged")
        let prepared = try XCTUnwrap(PhotoPreparation.prepare(data: small, filename: "wide.png", maxDimension: 20))
        XCTAssertEqual(prepared.contentType, "image/jpeg")
        XCTAssertEqual(prepared.filename, "wide.jpg")
        XCTAssertEqual(PhotoPreparation.sniffType(prepared.data), "image/jpeg")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 20)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 5)
        #else
        throw XCTSkip("ImageIO only")
        #endif
    }
}
