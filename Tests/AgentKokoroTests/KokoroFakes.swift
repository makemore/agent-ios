import Foundation
import CryptoKit
import AgentClient
@testable import AgentKokoro

// MARK: - Engine

final class FakeEngine: KokoroSynthesisEngine, @unchecked Sendable {
    struct Call: Equatable {
        let text: String
        let speakerId: Int
    }

    let sampleRate = 24_000
    private let lock = NSLock()
    private var _calls: [Call] = []
    /// Pieces of audio per utterance (each one "sentence").
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

    func synthesize(_ text: String, speakerId: Int, speed: Float, onAudio: ([Float]) -> Bool) throws {
        lock.lock(); _calls.append(Call(text: text, speakerId: speakerId)); lock.unlock()
        if failSynthesis { throw KokoroEngineError.synthesisFailed }
        for index in 0..<piecesPerUtterance {
            // Samples carry the piece index so the output can check order.
            let keepGoing = onAudio([Float](repeating: Float(index), count: 240))
            if index == 0 { firstPieceDelivered.signal() }
            if !keepGoing { stoppedEarly = true; return }
            if blockAfterFirstPiece {
                // Simulates a long synthesis: poll the callback the way the
                // real engine does between sentences.
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if !onAudio([]) { stoppedEarly = true; return }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }
    }
}

final class FakeEngineLoader: KokoroEngineLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var _loads: [KokoroVoice.Accent] = []
    var failLoad = false
    let engine = FakeEngine()

    var loads: [KokoroVoice.Accent] {
        lock.lock(); defer { lock.unlock() }
        return _loads
    }

    func loadEngine(modelDirectory: URL, accent: KokoroVoice.Accent) throws -> KokoroSynthesisEngine {
        lock.lock(); _loads.append(accent); lock.unlock()
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
        record(text)
    }

    private func record(_ text: String) {
        lock.lock(); _spoken.append(text); lock.unlock()
    }

    func cancel() {
        lock.lock(); _cancels += 1; lock.unlock()
    }

    func listVoices() async throws -> [VoiceDescriptor] { [] }
}

// MARK: - Fetcher (never touches the network)

final class FakeFetcher: KokoroAssetFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [URL] = []
    /// Bytes served per relative path. Missing paths fail with HTTP 404.
    var contents: [String: Data]
    /// Paths that fail with HTTP 500 (until removed).
    var failingPaths: Set<String> = []
    /// Paths whose fetch waits until the task is cancelled.
    var hangingPaths: Set<String> = []
    let hangStarted = DispatchSemaphore(value: 0)

    init(contents: [String: Data]) {
        self.contents = contents
    }

    var requested: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _requested
    }

    func fetch(_ url: URL, to destination: URL, allowsCellularAccess: Bool,
               relativePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let (failing, hanging, data) = record(url, relativePath: relativePath)
        if hanging {
            hangStarted.signal()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        }
        if failing { throw KokoroModelError.httpStatus(path: relativePath, status: 500) }
        guard let data else { throw KokoroModelError.httpStatus(path: relativePath, status: 404) }
        progress(Int64(data.count / 2))
        progress(Int64(data.count))
        try data.write(to: destination)
    }

    private func record(_ url: URL, relativePath: String) -> (Bool, Bool, Data?) {
        lock.lock(); defer { lock.unlock() }
        _requested.append(url)
        return (failingPaths.contains(relativePath), hangingPaths.contains(relativePath), contents[relativePath])
    }
}

// MARK: - Helpers

enum KokoroTestSupport {
    static let fileA = Data("hello kokoro".utf8)
    static let fileB = Data("abc".utf8)

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static var manifest: KokoroModelManifest {
        KokoroModelManifest(id: "test-model", files: [
            KokoroModelFile(path: "model.bin", bytes: Int64(fileA.count), sha256: sha256(fileA)),
            KokoroModelFile(path: "data/b.txt", bytes: Int64(fileB.count)),
        ])
    }

    static var contents: [String: Data] { ["model.bin": fileA, "data/b.txt": fileB] }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKokoroTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func manager(directory: URL, fetcher: FakeFetcher,
                        baseURL: URL = URL(string: "https://models.invalid/kokoro/")!) -> KokoroModelManager {
        KokoroModelManager(
            configuration: .init(baseURL: baseURL, cacheDirectory: directory, manifest: manifest),
            fetcher: fetcher
        )
    }

    /// A manager whose model is already installed.
    static func installedManager() async throws -> (KokoroModelManager, URL) {
        let dir = temporaryDirectory()
        let manager = manager(directory: dir, fetcher: FakeFetcher(contents: contents))
        try await manager.download()
        return (manager, dir)
    }
}
