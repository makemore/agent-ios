import Foundation
import Compression

/// `manifest.json` of a kokoro asset set (spec, "File formats"). Every file
/// a device fetches is listed with its size and SHA-256.
struct KokoroManifest: Decodable, Equatable {
    static let format = "kokoro-asset-manifest/1"

    struct File: Decodable, Equatable {
        let path: String
        let size: Int64
        let sha256: String
        let role: String?
    }

    struct G2PEntry: Decodable, Equatable {
        let gold: String
        let silver: String
        let model: String
        let vocab: String
    }

    struct Entry: Decodable, Equatable {
        let model: String
        let vocab: String
        let voices: String
        let g2p: [String: G2PEntry]
    }

    let format: String
    let version: String
    let sample_rate: Int
    let entry: Entry
    let files: [File]

    static func parse(_ data: Data) throws -> KokoroManifest {
        guard let manifest = try? JSONDecoder().decode(KokoroManifest.self, from: data),
              manifest.format == format else {
            throw KokoroModelError.invalidManifest
        }
        return manifest
    }

    func file(_ path: String) -> File? { files.first { $0.path == path } }

    /// The download for a JSON dictionary: its `.gz` copy when listed.
    func preferredFile(_ path: String) -> File? {
        file(path + ".gz") ?? file(path)
    }

    /// The local files one voice needs, by role, as manifest entries: the
    /// model and its vocab, `voices.json`, the voice pack, and the
    /// language's G2P (gzip dictionaries, BART model, BART vocab).
    func requirements(voiceId: String) throws -> KokoroRequirements {
        guard let language = KokoroLanguage(voiceId: voiceId),
              let g2p = entry.g2p[language.rawValue] else {
            throw KokoroModelError.unknownVoice(voiceId)
        }
        func need(_ path: String, preferGzip: Bool = false) throws -> File {
            guard let f = preferGzip ? preferredFile(path) : file(path) else {
                throw KokoroModelError.invalidManifest
            }
            return f
        }
        guard let voice = file("voices/\(voiceId).bin") else { throw KokoroModelError.unknownVoice(voiceId) }
        return KokoroRequirements(
            language: language,
            model: try need(entry.model),
            vocab: try need(entry.vocab),
            voices: try need(entry.voices),
            voice: voice,
            gold: try need(g2p.gold, preferGzip: true),
            silver: try need(g2p.silver, preferGzip: true),
            g2pModel: try need(g2p.model),
            g2pVocab: try need(g2p.vocab))
    }
}

/// What one voice needs on the device.
struct KokoroRequirements: Equatable {
    let language: KokoroLanguage
    let model: KokoroManifest.File
    let vocab: KokoroManifest.File
    let voices: KokoroManifest.File
    let voice: KokoroManifest.File
    let gold: KokoroManifest.File
    let silver: KokoroManifest.File
    let g2pModel: KokoroManifest.File
    let g2pVocab: KokoroManifest.File

    var files: [KokoroManifest.File] { [model, vocab, voices, voice, gold, silver, g2pModel, g2pVocab] }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// Verified local copies of the files one voice needs, for the engine.
struct KokoroAssetFiles: Equatable, Sendable {
    let language: KokoroLanguage
    let voiceId: String
    let model: URL
    let vocab: URL
    let voice: URL
    let gold: URL
    let silver: URL
    let g2pModel: URL
    let g2pVocab: URL

    /// Reads a dictionary, decompressing a `.gz` copy.
    static func readDictionary(_ url: URL, gzipped: Bool) throws -> Data {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return gzipped ? try Gzip.decompress(data) : data
    }
}

/// gzip (RFC 1952) decoding on Apple's Compression framework (raw DEFLATE).
enum Gzip {
    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw KokoroModelError.invalidAsset("gzip header")
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else { throw KokoroModelError.invalidAsset("gzip header") }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < bytes.count - 8 else { throw KokoroModelError.invalidAsset("gzip header") }
        let n = bytes.count
        let isize = Int(bytes[n - 4]) | Int(bytes[n - 3]) << 8 | Int(bytes[n - 2]) << 16 | Int(bytes[n - 1]) << 24
        // ISIZE is the size mod 2^32; our dictionaries are far below that.
        var out = Data(count: max(isize, 1))
        let written = out.withUnsafeMutableBytes { dst in
            bytes.withUnsafeBufferPointer { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, isize,
                                          src.baseAddress! + offset, n - 8 - offset,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == isize else { throw KokoroModelError.invalidAsset("gzip data") }
        out.count = isize
        return out
    }
}
