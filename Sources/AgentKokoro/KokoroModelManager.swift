import Foundation
import Combine
import CryptoKit
import AgentClient

/// Where the Kokoro model is in its download lifecycle.
public enum KokoroModelState: Equatable, Sendable {
    /// Not on the device. Speech uses the system voice until it is.
    case notDownloaded
    /// Downloading; `progress` is the fraction of bytes received, 0...1.
    case downloading(progress: Double)
    /// Installed and verified; Kokoro speaks.
    case ready
    /// The last download failed. Files that completed are kept, so a
    /// retry resumes rather than starting over. `reason` is a short,
    /// content-free description.
    case failed(reason: String)
}

/// Why a model download did not complete.
public enum KokoroModelError: Error, Equatable, LocalizedError {
    case httpStatus(path: String, status: Int)
    case integrityCheckFailed(path: String)
    case insufficientStorage(requiredBytes: Int64)
    case invalidResponse(path: String)

    public var errorDescription: String? {
        switch self {
        case let .httpStatus(path, status):
            return "Kokoro model download failed (HTTP \(status) for \(path))"
        case let .integrityCheckFailed(path):
            return "Kokoro model file failed its integrity check (\(path))"
        case let .insufficientStorage(required):
            let mb = Int((Double(required) / 1_000_000).rounded(.up))
            return "Not enough free storage for the Kokoro model (\(mb) MB needed)"
        case let .invalidResponse(path):
            return "Kokoro model download returned no file (\(path))"
        }
    }
}

/// Downloads, caches and deletes the on-device Kokoro model.
///
/// The model is not bundled with the app. It is fetched once — on first
/// use by ``KokoroTTSProvider``, or ahead of time by calling ``download()``
/// — from ``Configuration/baseURL``, verified against the manifest's sizes
/// and checksums, and kept in ``Configuration/cacheDirectory`` (excluded
/// from iCloud backup). Only model files travel over the network: no text
/// is ever sent.
///
/// Observe ``state`` (published on the main thread) to show progress.
/// All methods are safe to call from any thread.
public final class KokoroModelManager: ObservableObject, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Upstream location of `kokoro-int8-multi-lang-v1_0` on Hugging Face,
        /// pinned to a revision so the checksums below stay valid.
        public static let defaultBaseURL = URL(string:
            "https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_0/resolve/2a360693d79b88b49b88e29aec2b53577f41f206/")!

        /// Default cache: `Application Support/AgentKokoro`. Not `Caches`,
        /// which the OS may purge under storage pressure and force a
        /// re-download.
        public static var defaultCacheDirectory: URL {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return base.appendingPathComponent("AgentKokoro", isDirectory: true)
        }

        /// Each manifest file is fetched from `baseURL` + its path. Point
        /// this at your own mirror (same files) to avoid Hugging Face.
        public var baseURL: URL
        public var cacheDirectory: URL
        /// Whether the download may use cellular data.
        public var allowsCellularAccess: Bool
        public var manifest: KokoroModelManifest

        public init(baseURL: URL = Configuration.defaultBaseURL,
                    cacheDirectory: URL = Configuration.defaultCacheDirectory,
                    allowsCellularAccess: Bool = true,
                    manifest: KokoroModelManifest = .englishInt8) {
            self.baseURL = baseURL
            self.cacheDirectory = cacheDirectory
            self.allowsCellularAccess = allowsCellularAccess
            self.manifest = manifest
        }
    }

    /// Shared manager with the default configuration.
    public static let shared = KokoroModelManager()

    public let configuration: Configuration

    /// Published mirror of ``currentState`` — updated on the main thread.
    @Published public private(set) var state: KokoroModelState

    private let fetcher: KokoroAssetFetching
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var truthState: KokoroModelState
    private var downloadTask: Task<Void, Error>?
    private var _revision = 0
    private var lastPublishedProgress = -1.0

    public convenience init(configuration: Configuration = Configuration()) {
        self.init(configuration: configuration, fetcher: URLSessionAssetFetcher())
    }

    init(configuration: Configuration, fetcher: KokoroAssetFetching) {
        self.configuration = configuration
        self.fetcher = fetcher
        let initial: KokoroModelState = Self.installedFilesPresent(configuration: configuration) ? .ready : .notDownloaded
        self.truthState = initial
        self.state = initial
    }

    // MARK: - Public API

    /// The model's directory in the cache.
    public var modelDirectory: URL {
        configuration.cacheDirectory.appendingPathComponent(configuration.manifest.id, isDirectory: true)
    }

    /// Thread-safe current state (``state`` lags it by one main-queue hop).
    public var currentState: KokoroModelState {
        lock.lock(); defer { lock.unlock() }
        return truthState
    }

    public var isInstalled: Bool { currentState == .ready }

    /// Total bytes a full download transfers.
    public var downloadSize: Int64 { configuration.manifest.totalBytes }

    /// Downloads the model if it is not installed. Concurrent calls share
    /// one download. Throws `CancellationError` if ``cancelDownload()`` or
    /// ``delete()`` interrupts it.
    public func download() async throws {
        let task: Task<Void, Error>? = withLock {
            if truthState == .ready { return nil }
            if let existing = downloadTask { return existing }
            let created = Task { [weak self] in
                guard let self else { return }
                try await self.performDownload()
            }
            downloadTask = created
            return created
        }
        try await task?.value
    }

    /// Starts ``download()`` in the background if it is not installed or
    /// already downloading. Failures land in ``state``.
    public func startDownloadIfNeeded() {
        lock.lock()
        let needed = truthState != .ready && downloadTask == nil
        lock.unlock()
        guard needed else { return }
        Task { try? await self.download() }
    }

    /// Stops an in-flight download. Files already completed are kept.
    public func cancelDownload() {
        lock.lock()
        let task = downloadTask
        lock.unlock()
        task?.cancel()
    }

    /// Removes the model from the device (cancelling any download). The
    /// next use downloads it again.
    public func delete() throws {
        lock.lock()
        let task = downloadTask
        downloadTask = nil
        _revision += 1
        lock.unlock()
        task?.cancel()
        if fileManager.fileExists(atPath: modelDirectory.path) {
            try fileManager.removeItem(at: modelDirectory)
        }
        setState(.notDownloaded)
    }

    // MARK: - Internal

    /// Bumped whenever the installed files change, so loaded engines know
    /// to reload.
    var revision: Int {
        lock.lock(); defer { lock.unlock() }
        return _revision
    }

    private static let markerName = ".installed"

    static func installedFilesPresent(configuration: Configuration) -> Bool {
        let fm = FileManager.default
        let dir = configuration.cacheDirectory.appendingPathComponent(configuration.manifest.id, isDirectory: true)
        let marker = dir.appendingPathComponent(markerName)
        guard let data = fm.contents(atPath: marker.path),
              String(decoding: data, as: UTF8.self) == configuration.manifest.id else { return false }
        return configuration.manifest.files.allSatisfy { file in
            let size = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(file.path).path)[.size]) as? NSNumber
            return size?.int64Value == file.bytes
        }
    }

    private func performDownload() async throws {
        let startRevision = revision
        do {
            try await downloadFiles()
            let stale: Bool = withLock {
                guard _revision == startRevision else { return true }
                _revision += 1
                return false
            }
            // A delete() during the last file wins: don't report ready.
            if stale { throw CancellationError() }
            // State first, then release the task slot, so a concurrent
            // download() never sees "not ready and nothing running".
            setState(.ready)
            clearDownloadTask()
        } catch {
            let stale = revision != startRevision
            defer { if !stale { clearDownloadTask() } }
            if !stale {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    setState(Self.installedFilesPresent(configuration: configuration) ? .ready : .notDownloaded)
                } else {
                    let reason = (error as? LocalizedError)?.errorDescription ?? "Kokoro model download failed"
                    AgentLog.error("[Kokoro] model download failed: \(Self.valueFreeDescription(error))")
                    setState(.failed(reason: reason))
                }
            }
            throw error
        }
    }

    private func clearDownloadTask() {
        withLock { downloadTask = nil }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func downloadFiles() async throws {
        let manifest = configuration.manifest
        let dir = modelDirectory
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        excludeFromBackup(configuration.cacheDirectory)
        // Stale marker from another manifest version must not survive.
        try? fileManager.removeItem(at: dir.appendingPathComponent(Self.markerName))

        let total = max(manifest.totalBytes, 1)
        var completed: Int64 = 0
        var remaining: [KokoroModelFile] = []
        for file in manifest.files {
            if sizeOfItem(dir.appendingPathComponent(file.path)) == file.bytes {
                // Only verified downloads are ever moved to their final
                // name, so a right-sized file is a completed one.
                completed += file.bytes
            } else {
                remaining.append(file)
            }
        }
        try checkFreeSpace(needed: manifest.totalBytes - completed, at: configuration.cacheDirectory)
        setState(.downloading(progress: Double(completed) / Double(total)))

        for file in remaining {
            try Task.checkCancellation()
            let destination = dir.appendingPathComponent(file.path)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = destination.appendingPathExtension("partial")
            try? fileManager.removeItem(at: partial)
            let base = completed
            let url = configuration.baseURL.appendingPathComponent(file.path)
            do {
                try await fetcher.fetch(url, to: partial, allowsCellularAccess: configuration.allowsCellularAccess,
                                        relativePath: file.path) { [weak self] received in
                    self?.setState(.downloading(progress: Double(base + min(received, file.bytes)) / Double(total)))
                }
                try verify(partial, against: file)
            } catch {
                try? fileManager.removeItem(at: partial)
                throw error
            }
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: partial, to: destination)
            completed += file.bytes
            setState(.downloading(progress: Double(completed) / Double(total)))
        }
        try Task.checkCancellation()
        try Data(manifest.id.utf8).write(to: dir.appendingPathComponent(Self.markerName), options: .atomic)
    }

    private func verify(_ url: URL, against file: KokoroModelFile) throws {
        guard sizeOfItem(url) == file.bytes else {
            throw KokoroModelError.integrityCheckFailed(path: file.path)
        }
        guard let expected = file.sha256?.lowercased() else { return }
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
        guard actual == expected else {
            throw KokoroModelError.integrityCheckFailed(path: file.path)
        }
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

    private func setState(_ newState: KokoroModelState) {
        lock.lock()
        if case let .downloading(progress) = newState {
            // Throttle to whole percent steps: per-packet updates would
            // flood the main queue during a 150 MB transfer.
            if case .downloading = truthState, abs(progress - lastPublishedProgress) < 0.01, progress < 1 {
                lock.unlock()
                return
            }
            lastPublishedProgress = progress
        } else {
            lastPublishedProgress = -1
        }
        truthState = newState
        lock.unlock()
        // Publish the latest truth rather than the captured value, so a
        // late progress hop can never overwrite a newer state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let latest = self.currentState
            if self.state != latest { self.state = latest }
        }
    }

    static func valueFreeDescription(_ error: Error) -> String {
        if let modelError = error as? KokoroModelError { return modelError.errorDescription ?? "model error" }
        if let urlError = error as? URLError { return "network error \(urlError.code.rawValue)" }
        return String(describing: type(of: error))
    }
}

// MARK: - Fetching

/// Downloads one file to a local URL. A seam for tests: the default is
/// ``URLSessionAssetFetcher``.
protocol KokoroAssetFetching: Sendable {
    /// Fetches `url` to `destination`, reporting bytes received so far.
    func fetch(_ url: URL, to destination: URL, allowsCellularAccess: Bool,
               relativePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws
}

struct URLSessionAssetFetcher: KokoroAssetFetching {
    var session: URLSession = .shared

    func fetch(_ url: URL, to destination: URL, allowsCellularAccess: Bool,
               relativePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = allowsCellularAccess
        let holder = DownloadTaskHolder()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: request) { temp, response, error in
                    holder.finish()
                    if let error {
                        let cancelled = (error as? URLError)?.code == .cancelled
                        cont.resume(throwing: cancelled ? CancellationError() : error)
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        cont.resume(throwing: KokoroModelError.invalidResponse(path: relativePath))
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        cont.resume(throwing: KokoroModelError.httpStatus(path: relativePath, status: http.statusCode))
                        return
                    }
                    guard let temp else {
                        cont.resume(throwing: KokoroModelError.invalidResponse(path: relativePath))
                        return
                    }
                    do {
                        // The temporary file is deleted when this handler
                        // returns, so it has to be moved now.
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: temp, to: destination)
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                let observation = task.progress.observe(\.completedUnitCount) { p, _ in
                    progress(p.completedUnitCount)
                }
                holder.start(task, observation: observation)
            }
        } onCancel: {
            holder.cancel()
        }
    }
}

/// Keeps a download task and its progress observation alive, and lets a
/// cancellation that races task creation still cancel it.
private final class DownloadTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func start(_ task: URLSessionDownloadTask, observation: NSKeyValueObservation) {
        lock.lock()
        self.task = task
        self.observation = observation
        let cancelled = self.cancelled
        lock.unlock()
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func finish() {
        lock.lock()
        observation?.invalidate()
        observation = nil
        lock.unlock()
    }
}
