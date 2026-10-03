import Foundation
import AgentClient

/// One Kokoro v1.0 voice, identified the way Kokoro names it (`af_heart`,
/// `bm_george`, …) so the same id selects the same voice on iOS, Android
/// and the web widget.
///
/// The prefix encodes accent and gender: `a` American / `b` British,
/// `f` female / `m` male. Only the English voices are listed: they are the
/// ones the downloaded model files cover (American and British lexicons),
/// and the set the other platforms ship.
public struct KokoroVoice: Identifiable, Hashable, Sendable {
    public enum Accent: String, Sendable {
        case american = "en-US"
        case british = "en-GB"

        /// BCP-47 language tag for the accent.
        public var languageCode: String { rawValue }
    }

    public enum Gender: String, Sendable {
        case female
        case male
    }

    /// Kokoro's own voice id, e.g. `"af_heart"`.
    public let id: String
    /// Human label, e.g. `"Heart"`.
    public let displayName: String
    public let accent: Accent
    public let gender: Gender
    /// Row of this voice in the model's `voices.bin` (Kokoro v1.0 order).
    let speakerId: Int

    init(_ id: String, _ displayName: String, _ speakerId: Int) {
        self.id = id
        self.displayName = displayName
        self.speakerId = speakerId
        self.accent = id.hasPrefix("b") ? .british : .american
        self.gender = id.dropFirst().hasPrefix("m") ? .male : .female
    }

    /// Looks a voice up by its Kokoro id. `nil` for an unknown id.
    public init?(id: String) {
        guard let voice = Self.all.first(where: { $0.id == id }) else { return nil }
        self = voice
    }

    /// `"Heart (US, female)"` — a label suitable for a picker.
    public var label: String {
        let region = accent == .american ? "US" : "UK"
        return "\(displayName) (\(region), \(gender.rawValue))"
    }

    /// The voice used when none is chosen — Kokoro's own default.
    public static let defaultVoice = KokoroVoice("af_heart", "Heart", 3)

    /// Every voice this provider can speak in. Speaker ids follow the
    /// sherpa-onnx `kokoro-multi-lang-v1_0` voice table.
    public static let all: [KokoroVoice] = [
        KokoroVoice("af_alloy", "Alloy", 0),
        KokoroVoice("af_aoede", "Aoede", 1),
        KokoroVoice("af_bella", "Bella", 2),
        defaultVoice,
        KokoroVoice("af_jessica", "Jessica", 4),
        KokoroVoice("af_kore", "Kore", 5),
        KokoroVoice("af_nicole", "Nicole", 6),
        KokoroVoice("af_nova", "Nova", 7),
        KokoroVoice("af_river", "River", 8),
        KokoroVoice("af_sarah", "Sarah", 9),
        KokoroVoice("af_sky", "Sky", 10),
        KokoroVoice("am_adam", "Adam", 11),
        KokoroVoice("am_echo", "Echo", 12),
        KokoroVoice("am_eric", "Eric", 13),
        KokoroVoice("am_fenrir", "Fenrir", 14),
        KokoroVoice("am_liam", "Liam", 15),
        KokoroVoice("am_michael", "Michael", 16),
        KokoroVoice("am_onyx", "Onyx", 17),
        KokoroVoice("am_puck", "Puck", 18),
        KokoroVoice("am_santa", "Santa", 19),
        KokoroVoice("bf_alice", "Alice", 20),
        KokoroVoice("bf_emma", "Emma", 21),
        KokoroVoice("bf_isabella", "Isabella", 22),
        KokoroVoice("bf_lily", "Lily", 23),
        KokoroVoice("bm_daniel", "Daniel", 24),
        KokoroVoice("bm_fable", "Fable", 25),
        KokoroVoice("bm_george", "George", 26),
        KokoroVoice("bm_lewis", "Lewis", 27),
    ]

    /// The voices as ``VoiceDescriptor``s, for hosts that list voices
    /// through ``TTSProvider/listVoices()``.
    public static var descriptors: [VoiceDescriptor] {
        all.map { voice in
            VoiceDescriptor(id: voice.id, name: voice.displayName, labels: [
                "engine": "kokoro",
                "lang": voice.accent.languageCode,
                "gender": voice.gender.rawValue,
                "label": voice.label,
            ])
        }
    }
}
