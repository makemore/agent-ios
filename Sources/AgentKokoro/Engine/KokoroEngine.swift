import Foundation
#if os(iOS)
import UIKit
#endif

/// What one ``KokoroSynthesisEngine/synthesize(_:voice:speed:onAudio:)``
/// call did.
struct KokoroSynthesisStats: Equatable {
    var chunkCount = 0
    var audioSamples = 0
    /// Seconds spent in G2P and the model.
    var synthSeconds: Double = 0
}

/// A loaded Kokoro model that turns text into PCM. Internal seam: the
/// provider talks to this protocol so tests can swap in a fake engine.
///
/// Engines are used from one serial background queue at a time.
protocol KokoroSynthesisEngine: AnyObject {
    /// Output sample rate in Hz (24 kHz for Kokoro).
    var sampleRate: Int { get }

    /// Loads what `files` adds to the engine (a language's G2P, a voice
    /// pack) if it is not loaded yet.
    func prepare(_ files: KokoroAssetFiles) throws

    /// Synthesises `text` synchronously, handing audio to `onAudio` in order
    /// as each chunk is ready. Returning `false` from `onAudio` stops
    /// generation early. Throws if nothing could be synthesised.
    func synthesize(_ text: String, voice: KokoroVoice, speed: Float,
                    onAudio: ([Float]) -> Bool) throws -> KokoroSynthesisStats
}

/// Loads an engine from verified local files.
protocol KokoroEngineLoading: Sendable {
    func loadEngine(_ files: KokoroAssetFiles) throws -> KokoroSynthesisEngine
}

enum KokoroEngineError: Error, Equatable {
    case loadFailed
    case synthesisFailed
    case invalidAsset(String)
}

/// Owns the loaded engine and the queue it runs on, shared by every
/// provider in the process: the model takes about 100 MB of memory, so two
/// chat screens must not each load their own copy. The queue is serial, so
/// synthesis happens in the order it was requested.
final class KokoroEngineHost: @unchecked Sendable {
    static let shared = KokoroEngineHost(loader: OnnxKokoroEngineLoader())

    /// Engine work is long and blocking: off the main actor and off the
    /// cooperative pool.
    let queue = DispatchQueue(label: "agent-kokoro.synthesis", qos: .userInitiated)
    private let loader: KokoroEngineLoading

    // Queue-only.
    private var loaded: (revision: Int, model: URL, engine: KokoroSynthesisEngine)?
    private var failed: (revision: Int, files: KokoroAssetFiles)?
    private var memoryObserver: NSObjectProtocol?

    init(loader: KokoroEngineLoading) {
        self.loader = loader
        #if os(iOS)
        // Under memory pressure, drop the model; the next chunk reloads it.
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.unload()
        }
        #endif
    }

    deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }

    /// The engine for `files`, loading or extending it if needed, and the
    /// milliseconds that took (0 when everything was loaded). Call on
    /// ``queue`` only.
    func engine(for files: KokoroAssetFiles, revision: Int) throws -> (KokoroSynthesisEngine, Double) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Files that failed to load fail the same way until they change;
        // don't spend seconds re-reading them on every chunk.
        if let failed, failed.revision == revision, failed.files == files { throw KokoroEngineError.loadFailed }
        let started = DispatchTime.now()
        do {
            let engine: KokoroSynthesisEngine
            if let loaded, loaded.revision == revision, loaded.model == files.model {
                engine = loaded.engine
            } else {
                loaded = nil // release the old one before loading another
                engine = try loader.loadEngine(files)
                loaded = (revision, files.model, engine)
            }
            try engine.prepare(files)
            failed = nil
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
            return (engine, ms < 1 ? 0 : ms)
        } catch {
            failed = (revision, files)
            throw error
        }
    }

    /// Loads in the background (``KokoroModelManager/prepare(voice:)``, turn
    /// start). Returns the load time in ms.
    func load(files: KokoroAssetFiles, revision: Int) async throws -> Double {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    cont.resume(returning: try self.engine(for: files, revision: revision).1)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Drops the loaded model (memory warning, deleted files).
    func unload() {
        queue.async { [weak self] in
            self?.loaded = nil
            self?.failed = nil
        }
    }
}

// MARK: - ONNX Runtime

struct OnnxKokoroEngineLoader: KokoroEngineLoading {
    /// ONNX Runtime intra-op threads for the Kokoro model.
    var threads = OnnxKokoroEngine.defaultThreads

    func loadEngine(_ files: KokoroAssetFiles) throws -> KokoroSynthesisEngine {
        try OnnxKokoroEngine(files: files, threads: threads)
    }
}

/// Kokoro v1.0 on ONNX Runtime with our G2P (dictionaries + BART fallback).
/// Keeps one Kokoro session, the G2P of the language in use, and the voice
/// packs used so far.
final class OnnxKokoroEngine: KokoroSynthesisEngine {
    /// Performance cores on current iPhones; more threads mostly add
    /// contention with the efficiency cores.
    static var defaultThreads: Int { min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)) }

    let model: KokoroModel
    var sampleRate: Int { model.vocab.sampleRate }
    private var g2p: (language: KokoroLanguage, files: KokoroAssetFiles, g2p: KokoroG2P)?
    private var voices: [String: KokoroVoicePack] = [:]
    /// Pause inserted where the input had a line break (spec recommendation).
    static let newlinePause = 0.08

    init(files: KokoroAssetFiles, threads: Int) throws {
        let vocab = try KokoroVocab(data: Data(contentsOf: files.vocab))
        model = try KokoroModel(model: files.model, vocab: vocab, threads: threads)
    }

    func prepare(_ files: KokoroAssetFiles) throws {
        if g2p?.language != files.language || g2p?.files != files {
            if g2p?.language != files.language { g2p = nil } // one language in memory at a time
            g2p = (files.language, files, try Self.loadG2P(files))
        }
        if voices[files.voiceId] == nil {
            voices[files.voiceId] = try KokoroVoicePack(data: Data(contentsOf: files.voice))
        }
    }

    static func loadG2P(_ files: KokoroAssetFiles) throws -> KokoroG2P {
        func dictionary(_ url: URL) throws -> [String: LexEntry] {
            let data = try KokoroAssetFiles.readDictionary(url, gzipped: url.pathExtension == "gz")
            return KokoroLexicon.grow(try KokoroLexicon.parseDictionary(data))
        }
        // The two dictionaries parse in parallel: about half the load time.
        var golds: [String: LexEntry] = [:]
        var silvers: [String: LexEntry] = [:]
        var errors: [Error] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            do {
                let d = try dictionary(i == 0 ? files.gold : files.silver)
                lock.lock(); if i == 0 { golds = d } else { silvers = d }; lock.unlock()
            } catch {
                lock.lock(); errors.append(error); lock.unlock()
            }
        }
        if let error = errors.first { throw error }
        let bart = try KokoroBartG2P(model: files.g2pModel, vocab: Data(contentsOf: files.g2pVocab))
        let lexicon = KokoroLexicon(british: files.language == .enGB, golds: golds, silvers: silvers)
        return KokoroG2P(language: files.language, lexicon: lexicon, fallback: bart)
    }

    func synthesize(_ text: String, voice: KokoroVoice, speed: Float,
                    onAudio: ([Float]) -> Bool) throws -> KokoroSynthesisStats {
        guard let g2p, g2p.language == voice.language, let pack = voices[voice.id] else {
            throw KokoroEngineError.loadFailed
        }
        var stats = KokoroSynthesisStats()
        // KPipeline splits on newlines first; each segment is phonemised alone.
        let segments = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for (index, segment) in segments.enumerated() {
            var started = DispatchTime.now()
            let result = try g2p.g2p(segment)
            let pieces = KokoroChunker.streamingPieces(result.tokens)
            if index > 0, stats.audioSamples > 0, !pieces.isEmpty {
                let pause = [Float](repeating: 0, count: Int(Double(sampleRate) * Self.newlinePause))
                stats.audioSamples += pause.count
                if !onAudio(pause) { return stats }
            }
            for piece in pieces {
                let audio = try model.synthesize(piece.phonemes, voice: pack, speed: speed)
                stats.synthSeconds += Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
                stats.chunkCount += 1
                stats.audioSamples += audio.count
                if !audio.isEmpty, !onAudio(audio) { return stats }
                started = DispatchTime.now()
            }
        }
        return stats
    }
}
