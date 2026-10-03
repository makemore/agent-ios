import XCTest
import Combine
@testable import AgentKokoro

final class KokoroModelManagerTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = KokoroTestSupport.temporaryDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testStartsNotDownloadedWithEmptyCache() {
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: [:]))
        XCTAssertEqual(manager.currentState, .notDownloaded)
        XCTAssertEqual(manager.state, .notDownloaded)
        XCTAssertFalse(manager.isInstalled)
        XCTAssertEqual(manager.downloadSize, Int64(KokoroTestSupport.fileA.count + KokoroTestSupport.fileB.count))
    }

    func testDownloadFetchesEveryFileFromBaseURLAndBecomesReady() async throws {
        let fetcher = FakeFetcher(contents: KokoroTestSupport.contents)
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: fetcher,
                                                baseURL: URL(string: "https://mirror.invalid/models/kokoro/")!)
        var published: [KokoroModelState] = []
        let sub = manager.$state.sink { published.append($0) }
        defer { sub.cancel() }

        try await manager.download()

        XCTAssertEqual(manager.currentState, .ready)
        XCTAssertEqual(fetcher.requested.map(\.absoluteString), [
            "https://mirror.invalid/models/kokoro/model.bin",
            "https://mirror.invalid/models/kokoro/data/b.txt",
        ])
        let installed = manager.modelDirectory
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("model.bin")), KokoroTestSupport.fileA)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("data/b.txt")), KokoroTestSupport.fileB)

        // The published mirror catches up on the main queue.
        await waitForMain { manager.state == .ready }
        XCTAssertEqual(published.first, .notDownloaded)
        XCTAssertEqual(published.last, .ready)
        let progress = published.compactMap { state -> Double? in
            if case let .downloading(p) = state { return p }
            return nil
        }
        XCTAssertFalse(progress.isEmpty, "download progress is reported")
        XCTAssertEqual(progress, progress.sorted(), "progress never goes backwards")
        XCTAssertTrue(progress.allSatisfy { (0...1).contains($0) })
    }

    func testInstalledModelIsFoundByANewManager() async throws {
        let fetcher = FakeFetcher(contents: KokoroTestSupport.contents)
        try await KokoroTestSupport.manager(directory: directory, fetcher: fetcher).download()

        let secondFetcher = FakeFetcher(contents: [:])
        let second = KokoroTestSupport.manager(directory: directory, fetcher: secondFetcher)
        XCTAssertEqual(second.currentState, .ready)
        try await second.download() // no-op
        XCTAssertTrue(secondFetcher.requested.isEmpty)
    }

    func testChecksumMismatchFailsAndLeavesNothingBehind() async throws {
        var bad = KokoroTestSupport.contents
        bad["model.bin"] = Data("hello KOKORO".utf8) // right size, wrong bytes
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: bad))

        do {
            try await manager.download()
            XCTFail("expected an integrity failure")
        } catch let error as KokoroModelError {
            XCTAssertEqual(error, .integrityCheckFailed(path: "model.bin"))
        }
        guard case .failed = manager.currentState else {
            return XCTFail("expected failed, got \(manager.currentState)")
        }
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: manager.modelDirectory.path)) ?? []
        XCTAssertFalse(files.contains("model.bin"))
        XCTAssertFalse(files.contains { $0.hasSuffix(".partial") })
    }

    func testWrongSizeFailsIntegrityCheck() async throws {
        var bad = KokoroTestSupport.contents
        bad["data/b.txt"] = Data("abcd".utf8)
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: bad))
        do {
            try await manager.download()
            XCTFail("expected an integrity failure")
        } catch let error as KokoroModelError {
            XCTAssertEqual(error, .integrityCheckFailed(path: "data/b.txt"))
        }
    }

    func testFailedDownloadResumesWithoutRefetchingCompletedFiles() async throws {
        let fetcher = FakeFetcher(contents: KokoroTestSupport.contents)
        fetcher.failingPaths = ["data/b.txt"]
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: fetcher)

        do {
            try await manager.download()
            XCTFail("expected HTTP failure")
        } catch let error as KokoroModelError {
            XCTAssertEqual(error, .httpStatus(path: "data/b.txt", status: 500))
        }
        guard case let .failed(reason) = manager.currentState else {
            return XCTFail("expected failed, got \(manager.currentState)")
        }
        XCTAssertTrue(reason.contains("500"))

        fetcher.failingPaths = []
        try await manager.download()
        XCTAssertEqual(manager.currentState, .ready)
        let fetchedPaths = fetcher.requested.map(\.lastPathComponent)
        XCTAssertEqual(fetchedPaths, ["model.bin", "b.txt", "b.txt"], "model.bin is not downloaded twice")
    }

    func testConcurrentDownloadsShareOneTransfer() async throws {
        let fetcher = FakeFetcher(contents: KokoroTestSupport.contents)
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: fetcher)
        async let first: Void = manager.download()
        async let second: Void = manager.download()
        _ = try await (first, second)
        XCTAssertEqual(fetcher.requested.count, 2)
        XCTAssertEqual(manager.currentState, .ready)
    }

    func testCancelDownloadReturnsToNotDownloaded() async throws {
        let fetcher = FakeFetcher(contents: KokoroTestSupport.contents)
        fetcher.hangingPaths = ["data/b.txt"]
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: fetcher)

        let download = Task { try await manager.download() }
        XCTAssertEqual(fetcher.hangStarted.wait(timeout: .now() + 5), .success)
        if case .downloading = manager.currentState {} else {
            XCTFail("expected downloading, got \(manager.currentState)")
        }
        manager.cancelDownload()
        do {
            try await download.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(manager.currentState, .notDownloaded)
    }

    func testDeleteRemovesTheModel() async throws {
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: KokoroTestSupport.contents))
        try await manager.download()
        let revisionBefore = manager.revision

        try manager.delete()

        XCTAssertEqual(manager.currentState, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.modelDirectory.path))
        XCTAssertNotEqual(manager.revision, revisionBefore, "loaded engines must notice the model changed")
        let fresh = KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: [:]))
        XCTAssertEqual(fresh.currentState, .notDownloaded)
    }

    func testMissingInstalledFileIsNotReady() async throws {
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: KokoroTestSupport.contents))
        try await manager.download()
        try FileManager.default.removeItem(at: manager.modelDirectory.appendingPathComponent("data/b.txt"))
        let fresh = KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: [:]))
        XCTAssertEqual(fresh.currentState, .notDownloaded)
    }

    func testDefaultConfigurationPointsAtUpstreamHuggingFace() {
        let config = KokoroModelManager.Configuration()
        XCTAssertEqual(config.baseURL.host, "huggingface.co")
        XCTAssertTrue(config.baseURL.path.contains("csukuangfj/kokoro-int8-multi-lang-v1_0"))
        XCTAssertEqual(config.manifest, .englishInt8)
        XCTAssertTrue(config.allowsCellularAccess)
        // ~156 MB: the size documented in the README.
        XCTAssertEqual(KokoroModelManifest.englishInt8.totalBytes, 155_566_995)
        XCTAssertTrue(KokoroModelManifest.englishInt8.files.contains { $0.path == "model.int8.onnx" })
    }

    private func waitForMain(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 {
            let done = await MainActor.run { condition() }
            if done { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
