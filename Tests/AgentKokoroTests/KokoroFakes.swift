import Foundation
import CryptoKit
import AgentClient
@testable import AgentKokoro

// MARK: - Engine

final class FakeEngine: KokoroSynthesisEngine, @unchecked Sendable {
    struct Call: Equatable {
        let text: String
        let voiceId: String
    }

    let sampleRate = 24_000
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _prepared: [String] = []
    /// Pieces of audio per utterance (each one "chunk").
    var piecesPerUtterance = 2
    /// Throw instead of producing audio.
    var failSynthesis = false
    /// Block inside synthesis until released or stopped by the callback.
    var blockAfterFirstPiece = false
    let firstPieceDelivered = DispatchSemaphore(value: 0)
    private var _stoppedEarly = false
    private(set) var stoppedEarly: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stoppedEarly }
        set { lock.lock(); _stoppedEarly = newValue; lock.unlock() }
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    /// Voice ids prepared, in order.
    var prepared: [String] {
        lock.lock(); defer { lock.unlock() }
        return _prepared
    }

    func prepare(_ files: KokoroAssetFiles) throws {
        lock.lock(); _prepared.append(files.voiceId); lock.unlock()
    }

    func synthesize(_ text: String, voice: KokoroVoice, speed: Float,
                    onAudio: ([Float]) -> Bool) throws -> KokoroSynthesisStats {
        lock.lock(); _calls.append(Call(text: text, voiceId: voice.id)); lock.unlock()
        if failSynthesis { throw KokoroEngineError.synthesisFailed }
        var stats = KokoroSynthesisStats()
        for index in 0..<piecesPerUtterance {
            // Samples carry the piece index so the output can check order.
            let keepGoing = onAudio([Float](repeating: Float(index), count: 240))
            stats.chunkCount += 1
            stats.audioSamples += 240
            stats.synthSeconds += 0.001
            if index == 0 { firstPieceDelivered.signal() }
            if !keepGoing { stoppedEarly = true; return stats }
            if blockAfterFirstPiece {
                // Simulates a long synthesis: poll the callback between chunks.
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if !onAudio([]) { stoppedEarly = true; return stats }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }
        return stats
    }
}

final class FakeEngineLoader: KokoroEngineLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var _loads: [KokoroLanguage] = []
    var failLoad = false
    let engine = FakeEngine()

    /// Engines created (the language of the files that triggered it).
    var loads: [KokoroLanguage] {
        lock.lock(); defer { lock.unlock() }
        return _loads
    }

    func loadEngine(_ files: KokoroAssetFiles) throws -> KokoroSynthesisEngine {
        lock.lock(); _loads.append(files.language); lock.unlock()
        if failLoad { throw KokoroEngineError.loadFailed }
        return engine
    }
}

// MARK: - Output

final class FakeOutput: KokoroAudioOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _utterances: [[Float]] = []
    private var _stops = 0
    private var stopped = false
    private var waiter: CheckedContinuation<Void, Error>?
    /// Hold `finish()` open until `stop()` — simulates long playback.
    var holdPlayback = false
    var failBegin = false
    /// False for an output that plays somewhere else (a host's own sink).
    var usesDeviceAudioSession = true
    let playbackStarted = DispatchSemaphore(value: 0)

    /// Samples enqueued per utterance, in order.
    var utterances: [[Float]] {
        lock.lock(); defer { lock.unlock() }
        return _utterances
    }

    var stops: Int {
        lock.lock(); defer { lock.unlock() }
        return _stops
    }

    func begin(sampleRate: Int) throws {
        if failBegin { throw KokoroEngineError.synthesisFailed }
        lock.lock(); _utterances.append([]); stopped = false; lock.unlock()
    }

    func enqueue(_ samples: [Float]) {
        lock.lock()
        if !stopped, !samples.isEmpty, !_utterances.isEmpty {
            _utterances[_utterances.count - 1].append(contentsOf: samples)
        }
        lock.unlock()
    }

    func finish() async throws {
        guard withLock({ holdPlayback }) else {
            if withLock({ stopped }) { throw CancellationError() }
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if stopped { lock.unlock(); cont.resume(throwing: CancellationError()); return }
            waiter = cont
            lock.unlock()
            playbackStarted.signal()
        }
    }

    /// Lets held playback finish normally; later utterances don't hold.
    func releasePlayback() {
        lock.lock()
        holdPlayback = false
        let cont = waiter
        waiter = nil
        lock.unlock()
        cont?.resume()
    }

    func stop() {
        lock.lock()
        _stops += 1
        stopped = true
        let cont = waiter
        waiter = nil
        lock.unlock()
        cont?.resume(throwing: CancellationError())
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

// MARK: - Fallback provider

final class FakeFallbackProvider: TTSProvider, @unchecked Sendable {
    let name = "fake-fallback"
    private let lock = NSLock()
    private var _spoken: [String] = []
    private var _cancels = 0

    var spoken: [String] {
        lock.lock(); defer { lock.unlock() }
        return _spoken
    }

    var cancels: Int {
        lock.lock(); defer { lock.unlock() }
        return _cancels
    }

    func speak(_ text: String, options: TTSSpeakOptions) async throws {
        lock.lock(); _spoken.append(text); lock.unlock()
    }

    func cancel() {
        lock.lock(); _cancels += 1; lock.unlock()
    }

    func listVoices() async throws -> [VoiceDescriptor] { [] }
}

// MARK: - Fetcher (never touches the network)

final class FakeFetcher: KokoroAssetFetching, @unchecked Sendable {
    struct Request: Equatable {
        let path: String
        /// Bytes already in the destination: a resume from there.
        let resumeFrom: Int64
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    /// Bytes served per relative path. Missing paths fail with HTTP 404.
    var contents: [String: Data]
    /// Paths that fail with HTTP 500 (until removed).
    var failingPaths: Set<String> = []
    /// Paths that write this many bytes, then fail with a network error
    /// (once each), like a dropped connection.
    var interruptAfter: [String: Int] = [:]
    /// Paths whose fetch waits until the task is cancelled.
    var hangingPaths: Set<String> = []
    /// Whether the "server" honours range requests.
    var supportsRange = true
    let hangStarted = DispatchSemaphore(value: 0)

    init(contents: [String: Data]) {
        self.contents = contents
    }

    /// `allowsCellularDownload` of each request, in order.
    private(set) var cellular: [Bool] = []

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var requestedPaths: [String] { requests.map(\.path) }

    func fetch(_ url: URL, to destination: URL, expectedSize: Int64?, allowsCellularDownload: Bool,
               relativePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let existing = ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
        lock.lock()
        _requests.append(Request(path: relativePath, resumeFrom: existing))
        cellular.append(allowsCellularDownload)
        let failing = failingPaths.contains(relativePath)
        let hanging = hangingPaths.contains(relativePath)
        let data = contents[relativePath]
        let interrupt = interruptAfter.removeValue(forKey: relativePath)
        let range = supportsRange
        lock.unlock()

        if hanging {
            hangStarted.signal()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        }
        if failing { throw KokoroModelError.httpStatus(path: relativePath, status: 500) }
        guard let data else { throw KokoroModelError.httpStatus(path: relativePath, status: 404) }
        let start = range && existing > 0 && existing < Int64(data.count) ? Int(existing) : 0
        var body = data[start...]
        if let interrupt { body = body.prefix(interrupt) }
        if start == 0 {
            try Data(body).write(to: destination)
        } else {
            let handle = try FileHandle(forWritingTo: destination)
            try handle.seekToEnd()
            try handle.write(contentsOf: body)
            try handle.close()
        }
        progress(Int64(start + body.count))
        if interrupt != nil { throw URLError(.networkConnectionLost) }
    }
}

// MARK: - A small fake asset set

enum KokoroTestSupport {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `{"Paris":"pˈɛɹɪs","hello":"həlˈO","read":{"DEFAULT":"ɹˈid","VBD":"ɹˈɛd","VBN":null}}`, gzipped.
    static let gzipDictionary = Data(base64Encoded:
        "H4sIAAAAAAAC/6tWCkgsyixWslIqON1xcvbJnSdXFSvpKGWk5uTkAwUzTs7MOd3hDxQpSk1MUbKqVnJxdXMM9QkByp3cebojMwUoFebkAuWenA3h+ylZ5ZXm5NTWAgAsTDjqXwAAAA==")!

    static let voiceIds = ["af_heart", "am_michael", "bf_emma", "bm_george"]

    /// Paths -> bytes of a fake kokoro asset set (not real models).
    static let contents: [String: Data] = {
        var c: [String: Data] = [
            "model/kokoro.onnx": Data("model-bytes-0123456789".utf8),
            "model/vocab.json": Data("{\"vocab\":{}}".utf8),
            "voices/voices.json": Data("""
                {"format":"kokoro-voices/1","default":{"en-us":"af_heart","en-gb":"bf_emma"},"voices":[
                {"id":"af_heart","lang":"en-us","gender":"female","grade":"A"},
                {"id":"bm_george","lang":"en-gb","gender":"male","grade":"C"}]}
                """.utf8),
        ]
        for id in voiceIds { c["voices/\(id).bin"] = Data("voice-\(id)".utf8) }
        for lang in ["en-us", "en-gb"] {
            c["g2p/\(lang)/gold.json"] = Data("{\"gold\":\"\(lang)\"}".utf8)
            c["g2p/\(lang)/gold.json.gz"] = gzipDictionary + Data(lang.utf8) // distinct bytes per language
            c["g2p/\(lang)/silver.json"] = Data("{\"silver\":\"\(lang)\"}".utf8)
            c["g2p/\(lang)/silver.json.gz"] = Data("silver-gz-\(lang)".utf8)
            c["g2p/\(lang)/g2p.onnx"] = Data("bart-\(lang)".utf8)
            c["g2p/\(lang)/g2p-vocab.json"] = Data("{\"v\":\"\(lang)\"}".utf8)
        }
        return c
    }()

    static func manifest(files: [String: Data] = contents) -> Data {
        let entries = files.keys.sorted().map { path -> [String: Any] in
            ["path": path, "size": files[path]!.count, "sha256": sha256(files[path]!), "license": "Apache-2.0"]
        }
        var g2p: [String: Any] = [:]
        for lang in ["en-us", "en-gb"] {
            g2p[lang] = ["gold": "g2p/\(lang)/gold.json", "silver": "g2p/\(lang)/silver.json",
                         "model": "g2p/\(lang)/g2p.onnx", "vocab": "g2p/\(lang)/g2p-vocab.json"]
        }
        let object: [String: Any] = [
            "format": "kokoro-asset-manifest/1", "name": "kokoro-en", "version": "v1", "sample_rate": 24000,
            "entry": ["model": "model/kokoro.onnx", "vocab": "model/vocab.json", "voices": "voices/voices.json", "g2p": g2p],
            "files": entries,
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Everything the fake server serves, manifest included.
    static func served(_ files: [String: Data] = contents) -> [String: Data] {
        var all = files
        all["manifest.json"] = manifest(files: files)
        return all
    }

    /// Files a fresh install of `voice` downloads, manifest included.
    static func expectedPaths(voice: String) -> Set<String> {
        let lang = voice.hasPrefix("b") ? "en-gb" : "en-us"
        return ["manifest.json", "model/kokoro.onnx", "model/vocab.json", "voices/voices.json", "voices/\(voice).bin",
                "g2p/\(lang)/gold.json.gz", "g2p/\(lang)/silver.json.gz", "g2p/\(lang)/g2p.onnx",
                "g2p/\(lang)/g2p-vocab.json"]
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKokoroTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func configuration(directory: URL, voice: String = "af_heart",
                              baseURL: URL = URL(string: "https://models.invalid/kokoro/v1/")!,
                              allowsCellularDownload: Bool = false) -> KokoroConfiguration {
        KokoroConfiguration(baseURL: baseURL, voice: voice, cacheDirectory: directory,
                            allowsCellularDownload: allowsCellularDownload, manifestSHA256: sha256(manifest()))
    }

    static func manager(directory: URL, fetcher: FakeFetcher, voice: String = "af_heart",
                        loader: FakeEngineLoader = FakeEngineLoader(),
                        baseURL: URL = URL(string: "https://models.invalid/kokoro/v1/")!) -> KokoroModelManager {
        KokoroModelManager(configuration: configuration(directory: directory, voice: voice, baseURL: baseURL),
                           fetcher: fetcher, engineHost: KokoroEngineHost(loader: loader))
    }

    /// A manager whose default voice is already installed.
    static func installedManager(voice: String = "af_heart",
                                 loader: FakeEngineLoader = FakeEngineLoader()) async throws -> (KokoroModelManager, URL) {
        let dir = temporaryDirectory()
        let manager = manager(directory: dir, fetcher: FakeFetcher(contents: served()), voice: voice, loader: loader)
        try await manager.prepare()
        return (manager, dir)
    }
}
