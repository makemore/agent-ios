import Foundation
import AVFoundation

/// Plays a stream of mono float PCM for one utterance at a time.
/// Internal seam: tests substitute a fake that records what it was given.
protocol KokoroAudioOutput: AnyObject {
    /// Prepares for a new utterance at `sampleRate`. Throws if the audio
    /// hardware cannot be started.
    func begin(sampleRate: Int) throws
    /// Queues samples behind anything already queued. Any thread.
    func enqueue(_ samples: [Float])
    /// Waits until everything queued has played. Throws
    /// `CancellationError` if ``stop()`` interrupts it.
    func finish() async throws
    /// Stops playback immediately and drops anything queued. Any thread;
    /// safe to call repeatedly.
    func stop()
}

/// ``KokoroAudioOutput`` on `AVAudioEngine` + `AVAudioPlayerNode`, so audio
/// can start while later sentences are still being synthesised.
final class AVAudioEngineOutput: KokoroAudioOutput, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?

    private let lock = NSLock()
    private var pendingBuffers = 0
    private var queuedSeconds: Double = 0
    private var stopped = false
    private var waiter: CheckedContinuation<Void, Error>?
    private var utterance = 0
    private var configObserver: NSObjectProtocol?

    init() {
        engine.attach(player)
        // A route or hardware-format change stops the engine without
        // completing scheduled buffers; release any waiter rather than
        // leave the voice queue hanging.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.release(throwing: nil)
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        player.stop()
        engine.stop()
    }

    func begin(sampleRate: Int) throws {
        lock.lock()
        utterance += 1
        pendingBuffers = 0
        queuedSeconds = 0
        stopped = false
        lock.unlock()

        if format?.sampleRate != Double(sampleRate) {
            guard let newFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else {
                throw KokoroEngineError.synthesisFailed
            }
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: newFormat)
            format = newFormat
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.play()
    }

    func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        pendingBuffers += 1
        queuedSeconds += Double(samples.count) / format.sampleRate
        let token = utterance
        lock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.bufferDidPlay(utterance: token)
        }
    }

    func finish() async throws {
        let (alreadyDone, wasStopped, seconds, token): (Bool, Bool, Double, Int) = {
            lock.lock(); defer { lock.unlock() }
            return (pendingBuffers == 0, stopped, queuedSeconds, utterance)
        }()
        if wasStopped { throw CancellationError() }
        if alreadyDone { return }
        // Watchdog: an audio-session interruption can pause the engine
        // without ever completing its buffers. Don't wait forever.
        let deadline = seconds + 3
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [weak self] in
            self?.release(throwing: nil, utterance: token)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if stopped {
                lock.unlock()
                cont.resume(throwing: CancellationError())
                return
            }
            if pendingBuffers == 0 || utterance != token {
                lock.unlock()
                cont.resume()
                return
            }
            waiter = cont
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        pendingBuffers = 0
        let cont = waiter
        waiter = nil
        lock.unlock()
        player.stop()
        cont?.resume(throwing: CancellationError())
    }

    private func bufferDidPlay(utterance token: Int) {
        lock.lock()
        guard token == utterance, !stopped else { lock.unlock(); return }
        pendingBuffers = max(0, pendingBuffers - 1)
        let cont = pendingBuffers == 0 ? waiter : nil
        if cont != nil { waiter = nil }
        lock.unlock()
        cont?.resume()
    }

    private func release(throwing error: Error?, utterance token: Int? = nil) {
        lock.lock()
        if let token, token != utterance { lock.unlock(); return }
        let cont = waiter
        waiter = nil
        lock.unlock()
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
    }
}
