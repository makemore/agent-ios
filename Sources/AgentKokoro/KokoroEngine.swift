import Foundation
import SherpaOnnx
#if os(iOS)
import UIKit
#endif

/// A loaded Kokoro model that turns text into PCM. Internal seam: the
/// provider talks to this protocol so tests can swap in a fake engine.
///
/// Engines are used from one serial background queue at a time.
protocol KokoroSynthesisEngine: AnyObject {
    /// Output sample rate in Hz (24 kHz for Kokoro).
    var sampleRate: Int { get }

    /// Synthesises `text` synchronously, handing audio to `onAudio` in
    /// order as each piece (roughly a sentence) is ready. Returning `false`
    /// from `onAudio` stops generation early. Throws if nothing could be
    /// synthesised.
    func synthesize(_ text: String, speakerId: Int, speed: Float,
                    onAudio: ([Float]) -> Bool) throws
}

/// Loads an engine from an installed model directory.
protocol KokoroEngineLoading: Sendable {
    func loadEngine(modelDirectory: URL, accent: KokoroVoice.Accent) throws -> KokoroSynthesisEngine
}

/// Owns the loaded engine and the queue it runs on, shared by every
/// provider in the process: the model takes well over 100 MB of memory, so
/// two chat screens must not each load their own copy. The queue is serial,
/// so synthesis happens in the order it was requested.
final class KokoroEngineHost: @unchecked Sendable {
    struct Key: Equatable {
        let directory: URL
        let accent: KokoroVoice.Accent
        let revision: Int
    }

    static let shared = KokoroEngineHost(loader: SherpaKokoroEngineLoader())

    /// Engine work is long and blocking: off the main actor and off the
    /// cooperative pool.
    let queue = DispatchQueue(label: "agent-kokoro.synthesis", qos: .userInitiated)
    private let loader: KokoroEngineLoading

    // Queue-only.
    private var loaded: (key: Key, engine: KokoroSynthesisEngine)?
    private var failedKey: Key?
    private var memoryObserver: NSObjectProtocol?

    init(loader: KokoroEngineLoading) {
        self.loader = loader
        #if os(iOS)
        // Under memory pressure, drop the model; the next chunk reloads it
        // (about half a second).
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.loaded = nil }
        }
        #endif
    }

    deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }

    /// The engine for `key`, loading it if needed. Call on ``queue`` only.
    func engine(for key: Key) throws -> KokoroSynthesisEngine {
        dispatchPrecondition(condition: .onQueue(queue))
        if let loaded, loaded.key == key { return loaded.engine }
        // A model that failed to load fails the same way until it changes;
        // don't spend seconds re-reading it on every chunk.
        if failedKey == key { throw KokoroEngineError.loadFailed }
        loaded = nil // release the old one before loading another
        do {
            let engine = try loader.loadEngine(modelDirectory: key.directory, accent: key.accent)
            loaded = (key, engine)
            failedKey = nil
            return engine
        } catch {
            failedKey = key
            throw error
        }
    }
}

enum KokoroEngineError: Error, Equatable {
    case loadFailed
    case synthesisFailed
}

// MARK: - sherpa-onnx

struct SherpaKokoroEngineLoader: KokoroEngineLoading {
    /// ONNX Runtime intra-op threads. Two keeps a phone responsive while
    /// still synthesising several times faster than real time.
    var numThreads = 2

    func loadEngine(modelDirectory: URL, accent: KokoroVoice.Accent) throws -> KokoroSynthesisEngine {
        try SherpaKokoroEngine(modelDirectory: modelDirectory, accent: accent, numThreads: numThreads)
    }
}

/// Kokoro-82M through sherpa-onnx's offline TTS (ONNX Runtime on the CPU).
final class SherpaKokoroEngine: KokoroSynthesisEngine {
    private let tts: SherpaOnnxOfflineTtsWrapper
    let sampleRate: Int

    init(modelDirectory: URL, accent: KokoroVoice.Accent, numThreads: Int) throws {
        func path(_ relative: String) -> String {
            modelDirectory.appendingPathComponent(relative).path
        }
        // The multi-lingual v1.0 model needs a lexicon. Words it lacks are
        // phonemised by espeak-ng from `espeak-ng-data`.
        let lexicon = accent == .british ? "lexicon-gb-en.txt" : "lexicon-us-en.txt"
        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: path("model.int8.onnx"),
            voices: path("voices.bin"),
            tokens: path("tokens.txt"),
            dataDir: path("espeak-ng-data"),
            lexicon: path(lexicon)
        )
        let model = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: numThreads, debug: 0)
        // One sentence per callback, so playback can start after the first
        // sentence instead of waiting for the whole chunk.
        var config = sherpaOnnxOfflineTtsConfig(model: model, maxNumSentences: 1)
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
        // sherpa-onnx validates the config (files present, readable) and
        // returns a null handle instead of a usable engine on failure.
        guard wrapper.tts != nil else { throw KokoroEngineError.loadFailed }
        let rate = Int(wrapper.sampleRate)
        guard rate > 0 else { throw KokoroEngineError.loadFailed }
        self.tts = wrapper
        self.sampleRate = rate
    }

    func synthesize(_ text: String, speakerId: Int, speed: Float,
                    onAudio: ([Float]) -> Bool) throws {
        try withoutActuallyEscaping(onAudio) { onAudio in
            let sink = AudioSink(onAudio)
            let arg = Unmanaged.passUnretained(sink).toOpaque()
            let callback: TtsProgressCallbackWithArg = { samples, count, _, arg in
                guard let arg else { return 0 }
                let sink = Unmanaged<AudioSink>.fromOpaque(arg).takeUnretainedValue()
                guard !sink.stopped else { return 0 }
                if let samples, count > 0 {
                    sink.delivered += Int(count)
                    let chunk = Array(UnsafeBufferPointer(start: samples, count: Int(count)))
                    if !sink.onAudio(chunk) {
                        sink.stopped = true
                        return 0
                    }
                }
                return 1
            }
            let generation = SherpaOnnxGenerationConfigSwift(silenceScale: 0.2, speed: speed, sid: speakerId)
            let audio = withExtendedLifetime(sink) {
                tts.generateWithConfig(text: text, config: generation, callback: callback, arg: arg)
            }
            if sink.stopped || sink.delivered > 0 { return }
            // No streamed pieces: use the whole result, if there is one.
            guard audio.audio != nil, audio.n > 0 else { throw KokoroEngineError.synthesisFailed }
            _ = onAudio(audio.samples)
        }
    }

    private final class AudioSink {
        let onAudio: ([Float]) -> Bool
        var delivered = 0
        var stopped = false
        init(_ onAudio: @escaping ([Float]) -> Bool) { self.onAudio = onAudio }
    }
}
