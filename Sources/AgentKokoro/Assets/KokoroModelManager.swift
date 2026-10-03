import Foundation
import Combine
import CryptoKit
import AgentClient

/// Host settings for the on-device Kokoro voice. The same names are used
/// on iOS, Android and the web widget.
public struct KokoroConfiguration: Sendable, Equatable {
    /// Our public copy of the kokoro/v1 asset set. Hosts may mirror the same
    /// files elsewhere and point ``baseURL`` at the mirror.
    public static let defaultBaseURL = URL(string: "https://storage.googleapis.com/makemore-voice-models/kokoro/v1/")!
    /// SHA-256 of kokoro/v1 `manifest.json`. The manifest lists the size and
    /// SHA-256 of every other file, so pinning it pins the whole set.
    public static let pinnedManifestSHA256 = "cae1de34396b147750deaaed7834f1713486b16ec78df4a1c124a47bdf4dfbf6"

    /// Default cache: `Application Support/AgentKokoro` (excluded from
    /// backup). Not `Caches`, which the OS may purge and force a re-download.
    public static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AgentKokoro", isDirectory: true)
    }

    /// Folder holding `manifest.json` and the files it lists.
    public var baseURL: URL
    /// Kokoro voice id (`af_heart`, `bf_emma`, …). Decides the language.
    public var voice: String
    /// Speaking rate, 0.5–2.0; 1.0 is Kokoro's natural pace.
    public var speed: Float
    public var cacheDirectory: URL
    /// Whether the ~97 MB download may use cellular data, a personal
    /// hotspot or Low Data Mode. Off by default: until the host opts in, the
    /// files are fetched on Wi-Fi or wired networks only, and Kokoro speaks
    /// with the system voice meanwhile.
    public var allowsCellularDownload: Bool
    /// Expected SHA-256 of `manifest.json`. Defaults to the pinned kokoro/v1
    /// manifest; set it for a different asset set, or nil to trust whatever
    /// manifest the host serves (each file is still checked against it).
    public var manifestSHA256: String?

    public init(baseURL: URL = KokoroConfiguration.defaultBaseURL,
                voice: String = KokoroVoice.defaultVoiceId,
                speed: Float = 1.0,
                cacheDirectory: URL = KokoroConfiguration.defaultCacheDirectory,
                allowsCellularDownload: Bool = false,
                manifestSHA256: String? = KokoroConfiguration.pinnedManifestSHA256) {
        self.baseURL = baseURL
        self.voice = voice
        self.speed = speed
        self.cacheDirectory = cacheDirectory
        self.allowsCellularDownload = allowsCellularDownload
        self.manifestSHA256 = manifestSHA256
    }
}

/// Where the model is in its lifecycle.
public enum KokoroModelState: Equatable, Sendable {
    /// The files for the voice are not on the device. Speech uses the
    /// system voice until they are.
    case notDownloaded
    /// Fetching files; see ``KokoroModelManager/progress``.
    case downloading
    /// Files verified; loading the model into memory.
    case loading
    /// Files on the device and verified. After ``KokoroModelManager/prepare(voice:)``
    /// the model is also loaded; otherwise it loads on first use.
    case ready
    /// The last attempt failed. Verified files are kept, and a partial file
    /// resumes, so a retry continues rather than starting over.
    case failed(KokoroModelError)
}

/// Download progress over the files one voice needs.
public struct KokoroModelProgress: Equatable, Sendable {
    public var bytesDownloaded: Int64
    public var bytesTotal: Int64
    /// 0...1.
    public var fraction: Double {
        bytesTotal > 0 ? min(1, Double(bytesDownloaded) / Double(bytesTotal)) : 0
    }

    public init(bytesDownloaded: Int64, bytesTotal: Int64) {
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
    }
}

/// Why preparing the model failed. Content-free: safe to log or show.
public enum KokoroModelError: Error, Equatable, Sendable, LocalizedError {
    case httpStatus(path: String, status: Int)
    case integrityCheckFailed(path: String)
    case insufficientStorage(requiredBytes: Int64)
    case invalidResponse(path: String)
    case invalidManifest
    case invalidAsset(String)
    case unknownVoice(String)
    case network(code: Int)
    case engineLoadFailed

    public var errorDescription: String? {
        switch self {
        case let .httpStatus(path, status):
            return "Kokoro download failed (HTTP \(status) for \(path))"
        case let .integrityCheckFailed(path):
            return "Kokoro file failed its integrity check (\(path))"
        case let .insufficientStorage(required):
            let mb = Int((Double(required) / 1_000_000).rounded(.up))
            return "Not enough free storage for the Kokoro voice (\(mb) MB needed)"
        case let .invalidResponse(path):
            return "Kokoro download returned no file (\(path))"
        case .invalidManifest:
            return "Kokoro manifest is missing, unexpected or failed its check"
        case let .invalidAsset(what):
            return "Kokoro file could not be read (\(what))"
        case let .unknownVoice(id):
            return "Unknown Kokoro voice \(id)"
        case let .network(code):
            return "Kokoro download failed (network error \(code))"
        case .engineLoadFailed:
            return "The Kokoro model could not be loaded"
        }
    }
}

/// Downloads, verifies, caches, loads and deletes the on-device Kokoro voice.
///
/// Nothing is bundled. ``prepare(voice:)`` (or ``prefetch(voice:)``, or the
/// first ``KokoroTTSProvider`` utterance) fetches `manifest.json` from
/// ``KokoroConfiguration/baseURL``, checks it against the pinned SHA-256,
/// then fetches only what the voice needs — the model (92.4 MB), its vocab,
/// the voice pack (0.5 MB) and that language's G2P (≈ 4.5 MB) — checking
/// each file's size and SHA-256. Files are cached by SHA-256 in
/// ``KokoroConfiguration/cacheDirectory``; an interrupted download resumes
/// with an HTTP range request. Only model files travel over the network:
/// no text is ever sent.
///
/// Observe ``state`` and ``progress`` (main thread) or set
/// ``onModelProgress``. All methods are safe to call from any thread.
public final class KokoroModelManager: ObservableObject, @unchecked Sendable {
    /// Shared manager with the default configuration.
    public static let shared = KokoroModelManager()

    public let configuration: KokoroConfiguration

    /// Published mirror of ``currentState`` — updated on the main thread.
    @Published public private(set) var state: KokoroModelState
    /// Published download progress — updated on the main thread.
    @Published public private(set) var progress = KokoroModelProgress(bytesDownloaded: 0, bytesTotal: 0)
    /// Called on the main thread as a download progresses (at most every
    /// whole percent, plus the final value).
    public var onModelProgress: ((KokoroModelProgress) -> Void)?

    private let fetcher: KokoroAssetFetching
    let engineHost: KokoroEngineHost
    private let fileManager = FileManager.default
    private let lock = NSLock()
    // Lock-protected.
    private var truthState: KokoroModelState
    private var manifest: KokoroManifest?
    private var pipeline: (voice: String, task: Task<Void, Error>)?
    private var _revision = 0
    private var lastPublishedFraction = -1.0
    /// Voice id -> all its files present. Cleared whenever files change, so
    /// the per-chunk checks (some on the main thread) do no file I/O.
    private var presence: [String: Bool] = [:]

    public convenience init(configuration: KokoroConfiguration = KokoroConfiguration()) {
        self.init(configuration: configuration, fetcher: URLSessionAssetFetcher(), engineHost: .shared)
    }

    init(configuration: KokoroConfiguration, fetcher: KokoroAssetFetching, engineHost: KokoroEngineHost) {
        self.configuration = configuration
        self.fetcher = fetcher
        self.engineHost = engineHost
        let cached = Self.readCachedManifest(configuration)
        let installed = cached.map { Self.filesPresent($0, voiceId: configuration.voice, configuration) } ?? false
        self.manifest = cached
        self.truthState = installed ? .ready : .notDownloaded
        self.state = self.truthState
    }

    // MARK: - Public API

    /// Thread-safe current state (``state`` lags it by one main-queue hop).
    public var currentState: KokoroModelState {
        lock.lock(); defer { lock.unlock() }
        return truthState
    }

    /// Whether every file `voice` needs is on the device and verified
    /// (default: the configured voice). Cheap: no hashing, no network.
    public func isDownloaded(voice: String? = nil) -> Bool {
        let voiceId = voice ?? configuration.voice
        let (manifest, cached, revision) = withLock { (self.manifest, presence[voiceId], _revision) }
        if let cached { return cached }
        guard let manifest else { return false }
        let present = Self.filesPresent(manifest, voiceId: voiceId, configuration)
        withLock { if _revision == revision { presence[voiceId] = present } }
        return present
    }

    /// Downloads (if needed), verifies and loads everything `voice` needs
    /// (default: the configured voice). Idempotent: concurrent calls for
    /// the same voice share one attempt. Throws `CancellationError` if
    /// ``cancel()`` or ``deleteDownloadedModel()`` interrupts it.
    public func prepare(voice: String? = nil) async throws {
        let voiceId = voice ?? configuration.voice
        let task: Task<Void, Error> = withLock {
            if let pipeline, pipeline.voice == voiceId { return pipeline.task }
            let previous = pipeline?.task
            let created = Task { [weak self] in
                _ = await previous?.result
                guard let self else { return }
                try await self.run(voiceId: voiceId)
            }
            pipeline = (voiceId, created)
            return created
        }
        defer {
            withLock { if pipeline?.task == task { pipeline = nil } }
        }
        try await task.value
    }

    /// Starts ``prepare(voice:)`` in the background. Failures land in ``state``.
    public func prefetch(voice: String? = nil) {
        Task { try? await self.prepare(voice: voice) }
    }

    /// Stops an in-flight download. Verified files and the partial file
    /// are kept, so the next attempt resumes.
    public func cancel() {
        let task = withLock { pipeline?.task }
        task?.cancel()
    }

    /// The voices of the asset set, from `voices/voices.json` (fetched with
    /// the manifest if needed, about 7 KB).
    public func voices() async throws -> [KokoroVoice] {
        let manifest = try await loadManifest()
        guard let file = manifest.file(manifest.entry.voices) else { throw KokoroModelError.invalidManifest }
        let url = try await ensure(file, progress: { _ in })
        return try Self.parseVoices(Data(contentsOf: url))
    }

    /// Bytes a voice needs on the device (download size for a fresh install).
    public func requiredBytes(voice: String? = nil) async throws -> Int64 {
        try await loadManifest().requirements(voiceId: voice ?? configuration.voice).totalBytes
    }

    /// Bytes the downloaded files use on disk.
    public var downloadedBytes: Int64 {
        var total = sizeOfItem(Self.manifestURL(configuration)) ?? 0
        guard let items = fileManager.enumerator(at: blobDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return total
        }
        for case let url as URL in items {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Removes every downloaded file (cancelling any download) and unloads
    /// the model. The next use downloads it again.
    public func deleteDownloadedModel() throws {
        let task = withLock { () -> Task<Void, Error>? in
            defer { pipeline = nil; manifest = nil; presence = [:]; _revision += 1 }
            return pipeline?.task
        }
        task?.cancel()
        engineHost.unload()
        // Only what this manager wrote: the cache directory may be shared.
        for url in [blobDirectory, Self.manifestURL(configuration),
                    configuration.cacheDirectory.appendingPathComponent("manifest.json.partial")]
        where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        setState(.notDownloaded)
    }

    // MARK: - Internal

    /// Bumped whenever the installed files are removed, so loaded engines
    /// know to reload.
    var revision: Int { withLock { _revision } }

    /// Local files for a voice that ``isDownloaded(voice:)``, for the engine.
    func assetFiles(voice voiceId: String) -> KokoroAssetFiles? {
        guard isDownloaded(voice: voiceId), let manifest = withLock({ self.manifest }),
              let req = try? manifest.requirements(voiceId: voiceId) else { return nil }
        let config = configuration
        let url = { (f: KokoroManifest.File) in Self.blobURL(f, config) }
        return KokoroAssetFiles(language: req.language, voiceId: voiceId, model: url(req.model),
                                vocab: url(req.vocab), voice: url(req.voice), gold: url(req.gold),
                                silver: url(req.silver), g2pModel: url(req.g2pModel), g2pVocab: url(req.g2pVocab))
    }

    var blobDirectory: URL { configuration.cacheDirectory.appendingPathComponent("blobs", isDirectory: true) }

    static func blobURL(_ file: KokoroManifest.File, _ configuration: KokoroConfiguration) -> URL {
        // Keep the extension: the engine tells `.gz` dictionaries apart by it.
        var name = file.sha256.lowercased()
        if file.path.hasSuffix(".gz") { name += ".gz" }
        return configuration.cacheDirectory.appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func manifestURL(_ configuration: KokoroConfiguration) -> URL {
        configuration.cacheDirectory.appendingPathComponent("manifest.json")
    }

    private static func readCachedManifest(_ configuration: KokoroConfiguration) -> KokoroManifest? {
        guard let data = try? Data(contentsOf: manifestURL(configuration)) else { return nil }
        if let pin = configuration.manifestSHA256, sha256(data) != pin.lowercased() { return nil }
        return try? KokoroManifest.parse(data)
    }

    static func filesPresent(_ manifest: KokoroManifest, voiceId: String, _ configuration: KokoroConfiguration) -> Bool {
        guard let req = try? manifest.requirements(voiceId: voiceId) else { return false }
        let fm = FileManager.default
        return req.files.allSatisfy { file in
            let size = (try? fm.attributesOfItem(atPath: blobURL(file, configuration).path)[.size]) as? NSNumber
            return size?.int64Value == file.size
        }
    }

    static func parseVoices(_ data: Data) throws -> [KokoroVoice] {
        struct File: Decodable {
            struct Voice: Decodable { let id: String; let lang: String; let gender: String; let grade: String? }
            let `default`: [String: String]?
            let voices: [Voice]
        }
        guard let f = try? JSONDecoder().decode(File.self, from: data) else {
            throw KokoroModelError.invalidAsset("voices.json")
        }
        let suggested = Set((f.default ?? [:]).values)
        return f.voices.compactMap { v in
            guard let lang = KokoroLanguage(rawValue: v.lang) else { return nil }
            return KokoroVoice(id: v.id, language: lang, gender: v.gender == "male" ? .male : .female,
                               grade: v.grade ?? "", suggested: suggested.contains(v.id))
        }
    }

    private func run(voiceId: String) async throws {
        let startRevision = revision
        do {
            let manifest = try await loadManifest()
            let req = try manifest.requirements(voiceId: voiceId)
            let missing = req.files.filter { !isBlobPresent($0) }
            if !missing.isEmpty {
                withLock { presence = [:] }
                defer { withLock { presence = [:] } }
                try await download(missing, total: req.totalBytes)
            }
            try Task.checkCancellation()
            guard revision == startRevision, let files = assetFiles(voice: voiceId) else { throw CancellationError() }
            setState(.loading)
            let loadMs = try await engineHost.load(files: files, revision: startRevision)
            if loadMs > 0 {
                AgentLog.debug(.voice, "[Kokoro] model loaded in \(Int(loadMs)) ms")
            }
            guard revision == startRevision else { throw CancellationError() }
            setState(.ready)
        } catch {
            guard revision == startRevision else { throw error }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                setState(isDownloaded() ? .ready : .notDownloaded)
                throw CancellationError()
            }
            let modelError = Self.modelError(error)
            AgentLog.error("[Kokoro] prepare failed: \(modelError.errorDescription ?? "error")")
            setState(.failed(modelError))
            throw modelError
        }
    }

    static func modelError(_ error: Error) -> KokoroModelError {
        if let e = error as? KokoroModelError { return e }
        if let e = error as? URLError { return .network(code: e.code.rawValue) }
        if error is KokoroEngineError { return .engineLoadFailed }
        return .invalidAsset(String(describing: type(of: error)))
    }

    /// The manifest, from the cache or the network, checked against the pin.
    private func loadManifest() async throws -> KokoroManifest {
        if let cached = withLock({ manifest }) { return cached }
        try fileManager.createDirectory(at: configuration.cacheDirectory, withIntermediateDirectories: true)
        excludeFromBackup(configuration.cacheDirectory)
        let partial = configuration.cacheDirectory.appendingPathComponent("manifest.json.partial")
        try? fileManager.removeItem(at: partial)
        try await fetcher.fetch(configuration.baseURL.appendingPathComponent("manifest.json"), to: partial,
                                expectedSize: nil, allowsCellularDownload: configuration.allowsCellularDownload,
                                relativePath: "manifest.json", progress: { _ in })
        let data = try Data(contentsOf: partial)
        try? fileManager.removeItem(at: partial)
        if let pin = configuration.manifestSHA256, Self.sha256(data) != pin.lowercased() {
            throw KokoroModelError.invalidManifest
        }
        let parsed = try KokoroManifest.parse(data)
        try data.write(to: Self.manifestURL(configuration), options: .atomic)
        withLock { manifest = parsed }
        return parsed
    }

    private func isBlobPresent(_ file: KokoroManifest.File) -> Bool {
        sizeOfItem(Self.blobURL(file, configuration)) == file.size
    }

    private func download(_ files: [KokoroManifest.File], total: Int64) async throws {
        try fileManager.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        let needed = files.reduce(0) { $0 + $1.size }
        try checkFreeSpace(needed: needed, at: configuration.cacheDirectory)
        var completed = total - needed
        setProgress(KokoroModelProgress(bytesDownloaded: completed, bytesTotal: total), force: true)
        setState(.downloading)
        for file in files {
            try Task.checkCancellation()
            let base = completed
            _ = try await ensure(file) { [weak self] received in
                self?.setProgress(KokoroModelProgress(bytesDownloaded: base + min(received, file.size), bytesTotal: total))
            }
            completed += file.size
            setProgress(KokoroModelProgress(bytesDownloaded: completed, bytesTotal: total), force: completed == total)
        }
    }

    /// The verified local copy of `file`, downloading (or resuming) it if needed.
    private func ensure(_ file: KokoroManifest.File, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let destination = Self.blobURL(file, configuration)
        if sizeOfItem(destination) == file.size { return destination }
        try fileManager.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        excludeFromBackup(configuration.cacheDirectory)
        let partial = destination.appendingPathExtension("partial")
        try await fetcher.fetch(configuration.baseURL.appendingPathComponent(file.path), to: partial,
                                expectedSize: file.size, allowsCellularDownload: configuration.allowsCellularDownload,
                                relativePath: file.path, progress: progress)
        do {
            try verify(partial, against: file)
        } catch {
            // A corrupt partial must not be resumed.
            try? fileManager.removeItem(at: partial)
            throw error
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: partial, to: destination)
        return destination
    }

    private func verify(_ url: URL, against file: KokoroManifest.File) throws {
        guard sizeOfItem(url) == file.size else { throw KokoroModelError.integrityCheckFailed(path: file.path) }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw KokoroModelError.integrityCheckFailed(path: file.path)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 1 << 20) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == file.sha256.lowercased() else { throw KokoroModelError.integrityCheckFailed(path: file.path) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func checkFreeSpace(needed: Int64, at url: URL) throws {
        guard needed > 0 else { return }
        #if os(iOS)
        let key = URLResourceKey.volumeAvailableCapacityForImportantUsageKey
        if let values = try? url.resourceValues(forKeys: [key]),
           let available = values.volumeAvailableCapacityForImportantUsage,
           available > 0, available < needed {
            throw KokoroModelError.insufficientStorage(requiredBytes: needed)
        }
        #endif
    }

    private func sizeOfItem(_ url: URL) -> Int64? {
        ((try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
    }

    private func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func setState(_ newState: KokoroModelState) {
        withLock { truthState = newState }
        // Publish the latest truth rather than the captured value, so a
        // late hop can never overwrite a newer state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let latest = self.currentState
            if self.state != latest { self.state = latest }
        }
    }

    private func setProgress(_ value: KokoroModelProgress, force: Bool = false) {
        let publish: Bool = withLock {
            // Whole-percent steps: per-packet updates would flood the main
            // queue during a 92 MB transfer.
            guard force || abs(value.fraction - lastPublishedFraction) >= 0.01 else { return false }
            lastPublishedFraction = value.fraction
            return true
        }
        guard publish else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.progress = value
            self.onModelProgress?(value)
        }
    }
}

// MARK: - Fetching

/// Downloads one file. A seam for tests: the default is ``URLSessionAssetFetcher``.
protocol KokoroAssetFetching: Sendable {
    /// Fetches `url` into `destination`. When `destination` already holds a
    /// prefix of the file (an interrupted download) the fetcher resumes
    /// from its end where the server allows it, otherwise it starts over.
    /// Reports the bytes in `destination` so far.
    func fetch(_ url: URL, to destination: URL, expectedSize: Int64?, allowsCellularDownload: Bool,
               relativePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// ``KokoroAssetFetching`` on `URLSession` with HTTP range resume.
struct URLSessionAssetFetcher: KokoroAssetFetching {
    func fetch(_ url: URL, to destination: URL, expectedSize: Int64?, allowsCellularDownload: Bool,
               relativePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        var existing = ((try? fm.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
        if let expectedSize, existing >= expectedSize {
            if existing == expectedSize { return } // complete; the caller verifies it
            try? fm.removeItem(at: destination)
            existing = 0
        }
        if existing == 0 {
            try? fm.removeItem(at: destination)
            fm.createFile(atPath: destination.path, contents: nil)
        }
        var request = URLRequest(url: url)
        request.allowsCellularAccess = allowsCellularDownload
        request.allowsExpensiveNetworkAccess = allowsCellularDownload
        request.allowsConstrainedNetworkAccess = allowsCellularDownload
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let download = RangeDownload(destination: destination, offset: existing, relativePath: relativePath,
                                     progress: progress)
        try await download.run(request)
    }
}

/// One streaming HTTP download that appends to a file.
private final class RangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let offset: Int64
    private let relativePath: String
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?

    init(destination: URL, offset: Int64, relativePath: String, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.offset = offset
        self.relativePath = relativePath
        self.progress = progress
    }

    func run(_ request: URLRequest) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                lock.lock()
                continuation = cont
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(KokoroModelError.invalidResponse(path: relativePath))
            return completionHandler(.cancel)
        }
        do {
            switch http.statusCode {
            case 206 where offset > 0:
                let h = try FileHandle(forWritingTo: destination)
                try h.seek(toOffset: UInt64(offset))
                set(handle: h, written: offset)
            case 200..<300:
                // The server ignored the range: start over.
                let h = try FileHandle(forWritingTo: destination)
                try h.truncate(atOffset: 0)
                set(handle: h, written: 0)
            case 416:
                // Our partial is longer than the file: drop it and retry later.
                try? FileManager.default.removeItem(at: destination)
                fail(KokoroModelError.httpStatus(path: relativePath, status: 416))
                return completionHandler(.cancel)
            default:
                fail(KokoroModelError.httpStatus(path: relativePath, status: http.statusCode))
                return completionHandler(.cancel)
            }
        } catch {
            fail(error)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let handle else { lock.unlock(); return }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
        } catch {
            if failure == nil { failure = error }
            lock.unlock()
            dataTask.cancel()
            return
        }
        let total = written
        lock.unlock()
        progress(total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        try? handle?.close()
        handle = nil
        let cont = continuation
        continuation = nil
        let stored = failure
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let stored {
            cont?.resume(throwing: stored)
        } else if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            cont?.resume(throwing: cancelled ? CancellationError() : error)
        } else {
            cont?.resume()
        }
    }

    private func set(handle: FileHandle, written: Int64) {
        lock.lock()
        self.handle = handle
        self.written = written
        lock.unlock()
    }

    private func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }
}
