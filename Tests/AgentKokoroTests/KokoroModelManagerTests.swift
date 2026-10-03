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
        XCTAssertFalse(manager.isDownloaded())
        XCTAssertNil(manager.assetFiles(voice: "af_heart"))
        XCTAssertEqual(manager.downloadedBytes, 0)
    }

    func testPrepareDownloadsOnlyWhatTheVoiceNeedsVerifiesAndLoads() async throws {
        let fetcher = FakeFetcher(contents: KokoroTestSupport.served())
        let loader = FakeEngineLoader()
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: fetcher, loader: loader,
                                                baseURL: URL(string: "https://mirror.invalid/models/kokoro/v1/")!)
        var published: [KokoroModelState] = []
        var progress: [KokoroModelProgress] = []
        let sub = manager.$state.sink { published.append($0) }
        defer { sub.cancel() }
        manager.onModelProgress = { progress.append($0) }

        try await manager.prepare()

        XCTAssertEqual(manager.currentState, .ready)
        XCTAssertEqual(Set(fetcher.requestedPaths), KokoroTestSupport.expectedPaths(voice: "af_heart"))
        XCTAssertEqual(fetcher.requestedPaths.first, "manifest.json")
        XCTAssertEqual(fetcher.requestedPaths.count, KokoroTestSupport.expectedPaths(voice: "af_heart").count,
                       "each file once; no plain-JSON dictionaries, no other language or voice")
        XCTAssertTrue(manager.isDownloaded())
        XCTAssertFalse(manager.isDownloaded(voice: "bf_emma"))
        XCTAssertEqual(loader.loads, [.enUS], "prepare loads the model")
        XCTAssertEqual(loader.engine.prepared, ["af_heart"])

        // Files are cached by SHA-256 and the engine sees verified copies.
        let files = try XCTUnwrap(manager.assetFiles(voice: "af_heart"))
        let gold = KokoroTestSupport.contents["g2p/en-us/gold.json.gz"]!
        XCTAssertEqual(files.gold.lastPathComponent, KokoroTestSupport.sha256(gold) + ".gz")
        XCTAssertEqual(try Data(contentsOf: files.gold), gold)
        XCTAssertEqual(files.language, .enUS)

        await waitForMain { manager.state == .ready && !progress.isEmpty && progress.last?.fraction == 1 }
        XCTAssertEqual(published.first, .notDownloaded)
        XCTAssertTrue(published.contains(.downloading))
        XCTAssertTrue(published.contains(.loading) || published.last == .ready)
        XCTAssertEqual(published.last, .ready)
        let fractions = progress.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted(), "progress never goes backwards")
        let required = try await manager.requiredBytes()
        XCTAssertEqual(progress.last?.bytesTotal, required)
        XCTAssertEqual(progress.last?.bytesDownloaded, required)
        XCTAssertGreaterThan(manager.downloadedBytes, 0)
    }

    func testCellularDownloadIsOptIn() async throws {
        let fetcher = FakeFetcher(contents: KokoroTestSupport.served())
        try await KokoroTestSupport.manager(directory: directory, fetcher: fetcher).prepare()
        XCTAssertFalse(fetcher.cellular.isEmpty)
        XCTAssertTrue(fetcher.cellular.allSatisfy { !$0 }, "default: Wi-Fi / wired only")

        let other = KokoroTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        let optedIn = FakeFetcher(contents: KokoroTestSupport.served())
        let manager = KokoroModelManager(
            configuration: KokoroTestSupport.configuration(directory: other, allowsCellularDownload: true),
            fetcher: optedIn, engineHost: KokoroEngineHost(loader: FakeEngineLoader()))
        try await manager.prepare()
        XCTAssertTrue(optedIn.cellular.allSatisfy { $0 })
    }

    func testInstalledVoiceIsFoundByANewManager() async throws {
        try await KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: KokoroTestSupport.served())).prepare()

        let secondFetcher = FakeFetcher(contents: [:])
        let second = KokoroTestSupport.manager(directory: directory, fetcher: secondFetcher)
        XCTAssertEqual(second.currentState, .ready)
        XCTAssertTrue(second.isDownloaded())
        try await second.prepare() // loads, fetches nothing
        XCTAssertTrue(secondFetcher.requests.isEmpty)
    }

    func testBadHashIsRejectedAndNothingIsKept() async throws {
        var bad = KokoroTestSupport.served()
        var bytes = [UInt8](bad["voices/af_heart.bin"]!)
        bytes[0] ^= 0xFF // right size, wrong bytes
        bad["voices/af_heart.bin"] = Data(bytes)
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: bad))

        do {
            try await manager.prepare()
            XCTFail("expected an integrity failure")
        } catch let error as KokoroModelError {
            XCTAssertEqual(error, .integrityCheckFailed(path: "voices/af_heart.bin"))
        }
        XCTAssertEqual(manager.currentState, .failed(.integrityCheckFailed(path: "voices/af_heart.bin")))
        XCTAssertFalse(manager.isDownloaded())
        let blobs = (try? FileManager.default.contentsOfDirectory(atPath: manager.blobDirectory.path)) ?? []
        let voiceHash = KokoroTestSupport.sha256(KokoroTestSupport.contents["voices/af_heart.bin"]!)
        XCTAssertFalse(blobs.contains { $0.hasPrefix(voiceHash) }, "neither the file nor its partial survives")
    }

    func testWrongSizeIsRejected() async throws {
        var bad = KokoroTestSupport.served()
        bad["model/vocab.json"] = Data("{\"vocab\":{}} ".utf8)
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: bad))
        do {
            try await manager.prepare()
            XCTFail("expected an integrity failure")
        } catch let error as KokoroModelError {
            XCTAssertEqual(error, .integrityCheckFailed(path: "model/vocab.json"))
        }
    }

    func testManifestThatDoesNotMatchThePinIsRejected() async throws {
        var served = KokoroTestSupport.served()
        served["manifest.json"] = KokoroTestSupport.manifest(files: KokoroTestSupport.contents.merging(
            ["model/kokoro.onnx": Data("tampered-model".utf8)]) { $1 })
        let fetcher = FakeFetcher(contents: served)
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: fetcher)
        do {
            try await manager.prepare()
            XCTFail("expected the manifest to be rejected")
        } catch let error as KokoroModelError {
            XCTAssertEqual(error, .invalidManifest)
        }
        XCTAssertEqual(fetcher.requestedPaths, ["manifest.json"], "nothing is fetched on an unpinned manifest")
    }

    func testInterruptedDownloadResumesFromThePartialFile() async throws {
        let fetcher = FakeFetcher(contents: KokoroTestSupport.served())
        fetcher.interruptAfter = ["model/kokoro.onnx": 7]
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: fetcher)

        do {
            try await manager.prepare()
            XCTFail("expected the dropped connection to fail the attempt")
        } catch let error as KokoroModelError {
            XCTAssertEqual(error, .network(code: URLError.networkConnectionLost.rawValue))
        }
        guard case .failed = manager.currentState else { return XCTFail("\(manager.currentState)") }
        let before = fetcher.requests

        try await manager.prepare()
        XCTAssertEqual(manager.currentState, .ready)
        let retry = Array(fetcher.requests.dropFirst(before.count))
        XCTAssertEqual(retry.first, .init(path: "model/kokoro.onnx", resumeFrom: 7), "resumes, not restarts")
        let completedFirstTime = Set(before.map(\.path)).subtracting(["model/kokoro.onnx"])
        XCTAssertTrue(Set(retry.map(\.path)).isDisjoint(with: completedFirstTime), "verified files are not fetched again")
        let model = try XCTUnwrap(manager.assetFiles(voice: "af_heart")).model
        XCTAssertEqual(try Data(contentsOf: model), KokoroTestSupport.contents["model/kokoro.onnx"])
    }

    func testServerWithoutRangeSupportRestartsTheFile() async throws {
        let fetcher = FakeFetcher(contents: KokoroTestSupport.served())
        fetcher.supportsRange = false
        fetcher.interruptAfter = ["model/kokoro.onnx": 5]
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: fetcher)
        try? await manager.prepare()
        try await manager.prepare()
        XCTAssertEqual(manager.currentState, .ready)
        let model = try XCTUnwrap(manager.assetFiles(voice: "af_heart")).model
        XCTAssertEqual(try Data(contentsOf: model), KokoroTestSupport.contents["model/kokoro.onnx"])
    }

    func testLanguageComesFromTheVoicePrefix() async throws {
        let fetcher = FakeFetcher(contents: KokoroTestSupport.served())
        let loader = FakeEngineLoader()
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: fetcher, loader: loader)

        try await manager.prepare(voice: "bm_george")
        XCTAssertEqual(Set(fetcher.requestedPaths), KokoroTestSupport.expectedPaths(voice: "bm_george"))
        XCTAssertTrue(manager.isDownloaded(voice: "bm_george"))
        XCTAssertFalse(manager.isDownloaded(voice: "af_heart"))
        XCTAssertEqual(manager.assetFiles(voice: "bm_george")?.language, .enGB)

        // Adding a US voice fetches only the US G2P and the voice pack: the
        // model is shared.
        let before = fetcher.requests.count
        try await manager.prepare(voice: "af_heart")
        XCTAssertEqual(Set(fetcher.requestedPaths.dropFirst(before)), [
            "voices/af_heart.bin", "g2p/en-us/gold.json.gz", "g2p/en-us/silver.json.gz",
            "g2p/en-us/g2p.onnx", "g2p/en-us/g2p-vocab.json",
        ])
        XCTAssertEqual(loader.loads, [.enGB], "one model in memory, extended with the second language")
        XCTAssertEqual(loader.engine.prepared, ["bm_george", "af_heart"])

        XCTAssertEqual(KokoroLanguage(voiceId: "af_heart"), .enUS)
        XCTAssertEqual(KokoroLanguage(voiceId: "bf_emma"), .enGB)
        XCTAssertNil(KokoroLanguage(voiceId: "zf_xiaobei"))
        do {
            try await manager.prepare(voice: "zf_xiaobei")
            XCTFail("expected unknown voice")
        } catch let error as KokoroModelError {
            XCTAssertEqual(error, .unknownVoice("zf_xiaobei"))
        }
    }

    func testConcurrentPreparesShareOneTransfer() async throws {
        let fetcher = FakeFetcher(contents: KokoroTestSupport.served())
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: fetcher)
        async let first: Void = manager.prepare()
        async let second: Void = manager.prepare()
        _ = try await (first, second)
        XCTAssertEqual(fetcher.requests.count, KokoroTestSupport.expectedPaths(voice: "af_heart").count)
        XCTAssertEqual(manager.currentState, .ready)
    }

    func testCancelReturnsToNotDownloaded() async throws {
        let fetcher = FakeFetcher(contents: KokoroTestSupport.served())
        fetcher.hangingPaths = ["model/kokoro.onnx"]
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: fetcher)

        let preparing = Task { try await manager.prepare() }
        XCTAssertEqual(fetcher.hangStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(manager.currentState, .downloading)
        manager.cancel()
        do {
            try await preparing.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(manager.currentState, .notDownloaded)
    }

    func testDeleteDownloadedModelRemovesEverything() async throws {
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: KokoroTestSupport.served()))
        try await manager.prepare()
        try Data("keep".utf8).write(to: directory.appendingPathComponent("host-file.txt"))
        let revisionBefore = manager.revision
        XCTAssertGreaterThan(manager.downloadedBytes, 0)

        try manager.deleteDownloadedModel()

        XCTAssertEqual(manager.currentState, .notDownloaded)
        XCTAssertFalse(manager.isDownloaded())
        XCTAssertEqual(manager.downloadedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.blobDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("host-file.txt").path),
                      "files the manager did not write are left alone")
        XCTAssertNotEqual(manager.revision, revisionBefore, "loaded engines must notice the files changed")
        let fresh = KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: [:]))
        XCTAssertEqual(fresh.currentState, .notDownloaded)
    }

    func testVoicesComeFromVoicesJSON() async throws {
        let manager = KokoroTestSupport.manager(directory: directory, fetcher: FakeFetcher(contents: KokoroTestSupport.served()))
        let voices = try await manager.voices()
        XCTAssertEqual(voices.map(\.id), ["af_heart", "bm_george"])
        XCTAssertEqual(voices[0].name, "Heart")
        XCTAssertEqual(voices[0].language, .enUS)
        XCTAssertTrue(voices[0].suggested)
        XCTAssertEqual(voices[1].gender, .male)
        XCTAssertFalse(voices[1].suggested)

        // The real voices.json lists exactly the built-in catalogue.
        let real = try KokoroModelManager.parseVoices(Data(contentsOf: KokoroGolden.resource("voices.json")))
        XCTAssertEqual(real, KokoroVoice.all)
        XCTAssertEqual(real.filter(\.suggested).map(\.id), ["af_heart", "bf_emma"])
    }

    func testDefaultsPointAtOurPinnedKokoroV1() throws {
        let config = KokoroConfiguration()
        XCTAssertEqual(config.baseURL.absoluteString, "https://storage.googleapis.com/makemore-voice-models/kokoro/v1/")
        XCTAssertEqual(config.voice, "af_heart")
        XCTAssertEqual(config.speed, 1.0)
        XCTAssertFalse(config.allowsCellularDownload, "no ~97 MB download on cellular unless the host opts in")
        let manifest = try Data(contentsOf: KokoroGolden.resource("manifest.json"))
        XCTAssertEqual(config.manifestSHA256, KokoroTestSupport.sha256(manifest), "pin = hosted kokoro/v1 manifest")
    }

    /// What a user downloads per language with the real kokoro/v1 manifest.
    func testRealManifestDownloadSizes() throws {
        let manifest = try KokoroManifest.parse(Data(contentsOf: KokoroGolden.resource("manifest.json")))
        let us = try manifest.requirements(voiceId: "af_heart")
        let gb = try manifest.requirements(voiceId: "bf_emma")
        XCTAssertTrue(us.gold.path.hasSuffix(".gz") && us.silver.path.hasSuffix(".gz"))
        XCTAssertEqual(us.voice.size, 522_240)
        XCTAssertEqual(us.model.size, 92_361_116)
        print("[sizes] en-us (af_heart): \(us.totalBytes) bytes; en-gb (bf_emma): \(gb.totalBytes) bytes")
        XCTAssertLessThan(us.totalBytes, 98_000_000)
        XCTAssertLessThan(gb.totalBytes, 98_000_000)
    }

    func testGzipDecoding() throws {
        let data = try Gzip.decompress(KokoroTestSupport.gzipDictionary)
        let dict = try KokoroLexicon.parseDictionary(data)
        guard case .phonemes("həlˈO")? = dict["hello"], case let .tagged(tags)? = dict["read"] else {
            return XCTFail("\(dict)")
        }
        XCTAssertEqual(tags["VBD"], .some("ɹˈɛd"))
        XCTAssertEqual(tags["VBN"], .some(nil), "a null tag value is kept")
        XCTAssertThrowsError(try Gzip.decompress(Data("not gzip at all, really".utf8)))
        let grown = KokoroLexicon.grow(dict)
        XCTAssertNotNil(grown["Hello"])
        XCTAssertNotNil(grown["paris"])
        XCTAssertNil(grown["PARIS"])
    }

    private func waitForMain(_ condition: @escaping () -> Bool) async {
        for _ in 0..<400 {
            let done = await MainActor.run { condition() }
            if done { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
