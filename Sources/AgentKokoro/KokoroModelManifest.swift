import Foundation

/// One file of the Kokoro model, relative to the model's base URL and to
/// its directory in the on-device cache.
public struct KokoroModelFile: Hashable, Sendable {
    /// Relative path, e.g. `"model.int8.onnx"` or `"espeak-ng-data/en_dict"`.
    public let path: String
    /// Exact size in bytes; a download of any other size is rejected.
    public let bytes: Int64
    /// Lower-case hex SHA-256, checked after download when present.
    public let sha256: String?

    public init(path: String, bytes: Int64, sha256: String? = nil) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// The set of files that make up an installed Kokoro model.
///
/// The default, ``englishInt8``, is the int8-quantised Kokoro-82M v1.0
/// export that sherpa-onnx publishes (`kokoro-int8-multi-lang-v1_0`),
/// restricted to what the English voices need: the model, the voice table,
/// the American and British lexicons, and the English slice of the
/// espeak-ng phoneme data used for words missing from the lexicons.
public struct KokoroModelManifest: Hashable, Sendable {
    /// Stable identifier; also the name of the model's cache directory.
    /// Changing it installs side by side rather than over an older model.
    public let id: String
    public let files: [KokoroModelFile]

    public init(id: String, files: [KokoroModelFile]) {
        self.id = id
        self.files = files
    }

    /// Total download size in bytes.
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// Kokoro-82M v1.0, int8, English voices — about 156 MB (148 MiB).
    public static let englishInt8 = KokoroModelManifest(
        id: "kokoro-int8-multi-lang-v1_0-en",
        files: [
            KokoroModelFile(path: "model.int8.onnx", bytes: 114_203_756,
                            sha256: "4b86207ef680e394d8343bee22dfc4c512e5c707c6d9578e3f35ab09bffd6b36"),
            KokoroModelFile(path: "voices.bin", bytes: 28_200_960,
                            sha256: "1c5a5b983d3d50d8586d437a51f3faa2da7919ce76a013c081e65671a3447c29"),
            KokoroModelFile(path: "tokens.txt", bytes: 687),
            KokoroModelFile(path: "lexicon-us-en.txt", bytes: 5_956_885,
                            sha256: "7daaab53a181be9885b853a8582bf1838186317e5dadacbcef9c426d6fa0da14"),
            KokoroModelFile(path: "lexicon-gb-en.txt", bytes: 6_366_635,
                            sha256: "c4cbb37316f62210dff52718a7afcaae24f50c032cc75ab47ae67b831d1049e7"),
            KokoroModelFile(path: "espeak-ng-data/phontab", bytes: 55_796),
            KokoroModelFile(path: "espeak-ng-data/phonindex", bytes: 39_074),
            KokoroModelFile(path: "espeak-ng-data/phondata", bytes: 550_424,
                            sha256: "4e0288957874029a8c3c9f41a8f517ad4bf18127046decbdd4b9d1d6807ce3a3"),
            KokoroModelFile(path: "espeak-ng-data/phondata-manifest", bytes: 21_821),
            KokoroModelFile(path: "espeak-ng-data/intonations", bytes: 2_040),
            KokoroModelFile(path: "espeak-ng-data/en_dict", bytes: 166_944,
                            sha256: "71bd330ba8a2e3e8076e631508208ef49449d6147c17b7bd2b4b1e1468292e35"),
            KokoroModelFile(path: "espeak-ng-data/lang/gmw/en", bytes: 140),
            KokoroModelFile(path: "espeak-ng-data/lang/gmw/en-029", bytes: 335),
            KokoroModelFile(path: "espeak-ng-data/lang/gmw/en-GB-scotland", bytes: 295),
            KokoroModelFile(path: "espeak-ng-data/lang/gmw/en-GB-x-gbclan", bytes: 238),
            KokoroModelFile(path: "espeak-ng-data/lang/gmw/en-GB-x-gbcwmd", bytes: 188),
            KokoroModelFile(path: "espeak-ng-data/lang/gmw/en-GB-x-rp", bytes: 249),
            KokoroModelFile(path: "espeak-ng-data/lang/gmw/en-US", bytes: 257),
            KokoroModelFile(path: "espeak-ng-data/lang/gmw/en-US-nyc", bytes: 271),
        ]
    )
}
