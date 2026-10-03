import Foundation
import OnnxRuntimeBindings

/// ONNX Runtime plumbing shared by the Kokoro model and the BART G2P.
enum KokoroORT {
    /// One environment per process (ONNX Runtime's recommendation).
    static let env: ORTEnv? = {
        // The pinned 1.24.2 iOS/macOS build has no telemetry provider and no
        // network code. ONNX Runtime 1.29+ can send telemetry on POSIX
        // platforms when built with it; this opts out ahead of any future
        // bump (it does not override a value the host has set).
        setenv("ORT_DISABLE_TELEMETRY", "1", 0)
        return try? ORTEnv(loggingLevel: .warning)
    }()

    static func session(_ url: URL, threads: Int) throws -> ORTSession {
        guard let env else { throw KokoroEngineError.loadFailed }
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(threads))
        try options.setGraphOptimizationLevel(.all)
        // Worker threads sleep between runs instead of spin-waiting: on a
        // phone, spinning burns battery while audio plays, for no measured
        // gain in synthesis speed.
        try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
        return try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
    }

    static func int64Tensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * 8) }
        return try ORTValue(tensorData: data, elementType: .int64, shape: shape.map { NSNumber(value: $0) })
    }

    static func floatTensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * 4) }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    static func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

// MARK: - BART G2P

/// Greedy decoding of `g2p/<lang>/g2p.onnx` for words the dictionaries
/// cannot resolve (spec, "G2P ONNX contract"). Results are cached per word.
final class KokoroBartG2P: G2PFallback {
    static let pad: Int64 = 0, bos: Int64 = 1, eos: Int64 = 2, unk: Int64 = 3

    let maxPositions: Int
    let phonemeTokens: [String]
    private let graphemeToId: [Unicode.Scalar: Int64]
    private let session: ORTSession?
    private var cache: [String: String] = [:]

    struct Vocab: Decodable {
        let max_positions: Int
        let grapheme_tokens: [String]
        let phoneme_tokens: [String]
    }

    init(model: URL?, vocab: Data, threads: Int = 1) throws {
        let v = try JSONDecoder().decode(Vocab.self, from: vocab)
        maxPositions = v.max_positions
        phonemeTokens = v.phoneme_tokens
        var map: [Unicode.Scalar: Int64] = [:]
        for (i, g) in v.grapheme_tokens.enumerated() where i > Int(Self.unk) {
            let scalars = Array(g.unicodeScalars)
            if scalars.count == 1 { map[scalars[0]] = Int64(i) }
        }
        graphemeToId = map
        session = try model.map { try KokoroORT.session($0, threads: threads) }
    }

    func encode(_ word: String) -> [Int64] {
        [Self.bos] + word.unicodeScalars.map { graphemeToId[$0] ?? Self.unk } + [Self.eos]
    }

    /// One slice of at most `maxPositions - 2` code points. Returns the
    /// generated ids without the initial decoder BOS and without EOS.
    func decodeIds(_ word: String) throws -> (input: [Int64], output: [Int64]) {
        guard let session else { throw KokoroEngineError.loadFailed }
        let ids = encode(word)
        precondition(ids.count <= maxPositions)
        let encoder = try KokoroORT.int64Tensor(ids, shape: [1, ids.count])
        var dec: [Int64] = [Self.bos]
        while dec.count < maxPositions {
            let decoder = try KokoroORT.int64Tensor(dec, shape: [1, dec.count])
            let out = try session.run(withInputs: ["input_ids": encoder, "decoder_input_ids": decoder],
                                      outputNames: ["logits"], runOptions: nil)
            guard let logits = out["logits"] else { throw KokoroEngineError.synthesisFailed }
            let all = try KokoroORT.floats(logits)
            let vocabSize = all.count / dec.count
            let row = all[(dec.count - 1) * vocabSize ..< dec.count * vocabSize]
            // argmax: the first (lowest) index wins a tie.
            var best = row.startIndex
            for i in row.indices where row[i] > row[best] { best = i }
            let next = Int64(best - row.startIndex)
            if next == Self.eos { break }
            dec.append(next)
        }
        return (ids, Array(dec.dropFirst()))
    }

    func idsToPhonemes(_ ids: [Int64]) -> String {
        ids.filter { $0 > Self.unk && $0 < phonemeTokens.count }.map { phonemeTokens[Int($0)] }.joined()
    }

    func phonemes(for word: String) throws -> String {
        if let hit = cache[word] { return hit }
        let scalars = Array(word.unicodeScalars)
        let n = maxPositions - 2
        var ps = ""
        var i = 0
        while i < scalars.count {
            let slice = PyText.string(scalars[i..<min(i + n, scalars.count)])
            ps += idsToPhonemes(try decodeIds(slice).output)
            i += n
        }
        cache[word] = ps
        return ps
    }
}

// MARK: - Kokoro model

/// `model/vocab.json`: one code point -> one Kokoro token id.
struct KokoroVocab {
    let ids: [Unicode.Scalar: Int64]
    let maxPhonemeTokens: Int
    let sampleRate: Int

    private struct File: Decodable {
        let max_phoneme_tokens: Int
        let sample_rate: Int
        let vocab: [String: Int]
    }

    init(data: Data) throws {
        let f = try JSONDecoder().decode(File.self, from: data)
        var ids: [Unicode.Scalar: Int64] = [:]
        for (k, v) in f.vocab {
            let s = Array(k.unicodeScalars)
            if s.count == 1 { ids[s[0]] = Int64(v) }
        }
        self.ids = ids
        maxPhonemeTokens = f.max_phoneme_tokens
        sampleRate = f.sample_rate
    }

    /// Unknown characters are dropped.
    func tokenIds(_ phonemes: String) -> [Int64] {
        phonemes.unicodeScalars.compactMap { ids[$0] }
    }

    /// `[0] + ids + [0]`, or nil when there are more than 510 tokens.
    func modelInputIds(_ phonemes: String) -> [Int64]? {
        let t = tokenIds(phonemes)
        guard t.count <= maxPhonemeTokens else { return nil }
        return [0] + t + [0]
    }
}

/// A voice pack: little-endian float32 `[510, 1, 256]`.
struct KokoroVoicePack {
    static let rows = 510
    static let styleDim = 256
    let values: [Float]

    init(data: Data) throws {
        guard data.count == Self.rows * Self.styleDim * 4 else { throw KokoroEngineError.invalidAsset("voice") }
        values = data.withUnsafeBytes { raw in
            (0..<(Self.rows * Self.styleDim)).map { i in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            }
        }
    }

    /// hexgrad KPipeline uses `pack[len(ps) - 1]`.
    static func styleIndex(tokenCount: Int) -> Int {
        min(max(tokenCount - 1, 0), rows - 1)
    }

    func style(tokenCount: Int) -> [Float] {
        let row = Self.styleIndex(tokenCount: tokenCount)
        return Array(values[(row * Self.styleDim)..<((row + 1) * Self.styleDim)])
    }
}

/// `model/kokoro-v1.0-q8.onnx` (spec, "Kokoro inference contract").
final class KokoroModel {
    let session: ORTSession
    let vocab: KokoroVocab
    private let outputName: String

    init(model: URL, vocab: KokoroVocab, threads: Int) throws {
        session = try KokoroORT.session(model, threads: threads)
        self.vocab = vocab
        outputName = try session.outputNames().first ?? "waveform"
    }

    /// 24 kHz mono float PCM for one chunk of at most 510 phonemes, clipped
    /// to [-1, 1]. Empty phonemes produce no audio.
    func synthesize(_ phonemes: String, voice: KokoroVoicePack, speed: Float) throws -> [Float] {
        guard let ids = vocab.modelInputIds(phonemes) else { throw KokoroEngineError.synthesisFailed }
        guard ids.count > 2 else { return [] }
        let style = voice.style(tokenCount: ids.count - 2)
        let out = try session.run(withInputs: [
            "input_ids": try KokoroORT.int64Tensor(ids, shape: [1, ids.count]),
            "style": try KokoroORT.floatTensor(style, shape: [1, KokoroVoicePack.styleDim]),
            "speed": try KokoroORT.floatTensor([speed], shape: [1]),
        ], outputNames: [outputName], runOptions: nil)
        guard let wave = out[outputName] else { throw KokoroEngineError.synthesisFailed }
        return try KokoroORT.floats(wave).map { min(max($0, -1), 1) }
    }
}
