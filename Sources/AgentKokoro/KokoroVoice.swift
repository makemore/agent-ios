import Foundation
import AgentClient

/// The two English variants Kokoro v1.0 speaks. A voice's language comes
/// from its id prefix: `a*` is `en-us`, `b*` is `en-gb`.
public enum KokoroLanguage: String, Sendable, CaseIterable, Codable {
    case enUS = "en-us"
    case enGB = "en-gb"

    /// The language of a Kokoro voice id, or nil for a non-English id.
    public init?(voiceId: String) {
        switch voiceId.first {
        case "a": self = .enUS
        case "b": self = .enGB
        default: return nil
        }
    }

    /// BCP-47 tag, e.g. `en-US`.
    public var bcp47: String { self == .enUS ? "en-US" : "en-GB" }
}

/// One Kokoro v1.0 voice, identified the way Kokoro names it (`af_heart`,
/// `bm_george`, …) so the same id selects the same voice on iOS, Android
/// and the web widget.
///
/// The prefix encodes language and gender: `a` American / `b` British,
/// `f` female / `m` male. ``KokoroModelManager/voices()`` reads the list
/// from the downloaded `voices/voices.json`; ``all`` is the same list built
/// in, for pickers shown before anything is downloaded.
public struct KokoroVoice: Identifiable, Hashable, Sendable {
    public enum Gender: String, Sendable {
        case female
        case male
    }

    /// Kokoro's own voice id, e.g. `"af_heart"`.
    public let id: String
    /// Human label, e.g. `"Heart"`.
    public let name: String
    public let language: KokoroLanguage
    public let gender: Gender
    /// Kokoro's overall grade from `VOICES.md` (`"A"` best).
    public let grade: String
    /// The suggested voice for its language (`af_heart`, `bf_emma`).
    public let suggested: Bool

    public init(id: String, name: String? = nil, language: KokoroLanguage, gender: Gender,
                grade: String = "", suggested: Bool = false) {
        self.id = id
        self.name = name ?? Self.displayName(for: id)
        self.language = language
        self.gender = gender
        self.grade = grade
        self.suggested = suggested
    }

    /// Looks a voice up by its Kokoro id in ``all``. `nil` for an unknown id.
    public init?(id: String) {
        guard let voice = Self.all.first(where: { $0.id == id }) else { return nil }
        self = voice
    }

    /// `"Heart (US, female)"` — a label suitable for a picker.
    public var label: String {
        let region = language == .enUS ? "US" : "UK"
        return "\(name) (\(region), \(gender.rawValue))"
    }

    /// `af_heart` -> `Heart`.
    static func displayName(for id: String) -> String {
        guard let underscore = id.firstIndex(of: "_") else { return id }
        let rest = id[id.index(after: underscore)...]
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// The voice used when none is chosen — Kokoro's own default.
    public static let defaultVoiceId = "af_heart"
    public static var defaultVoice: KokoroVoice { KokoroVoice(id: defaultVoiceId)! }

    private static func v(_ id: String, _ grade: String, suggested: Bool = false) -> KokoroVoice {
        KokoroVoice(id: id, language: id.hasPrefix("b") ? .enGB : .enUS,
                    gender: id.dropFirst().hasPrefix("m") ? .male : .female, grade: grade, suggested: suggested)
    }

    /// Every voice in kokoro/v1 `voices/voices.json`, in its order.
    public static let all: [KokoroVoice] = [
        v("af_heart", "A", suggested: true), v("af_alloy", "C"), v("af_aoede", "C+"), v("af_bella", "A-"),
        v("af_jessica", "D"), v("af_kore", "C+"), v("af_nicole", "B-"), v("af_nova", "C"),
        v("af_river", "D"), v("af_sarah", "C+"), v("af_sky", "C-"),
        v("am_adam", "F+"), v("am_echo", "D"), v("am_eric", "D"), v("am_fenrir", "C+"),
        v("am_liam", "D"), v("am_michael", "C+"), v("am_onyx", "D"), v("am_puck", "C+"), v("am_santa", "D-"),
        v("bf_alice", "D"), v("bf_emma", "B-", suggested: true), v("bf_isabella", "C"), v("bf_lily", "D"),
        v("bm_daniel", "D"), v("bm_fable", "C"), v("bm_george", "C"), v("bm_lewis", "D+"),
    ]

    /// The voices as ``VoiceDescriptor``s, for hosts that list voices
    /// through ``TTSProvider/listVoices()``.
    public static func descriptors(_ voices: [KokoroVoice] = all) -> [VoiceDescriptor] {
        voices.map { voice in
            VoiceDescriptor(id: voice.id, name: voice.name, labels: [
                "engine": KokoroTTS.engineId,
                "lang": voice.language.rawValue,
                "gender": voice.gender.rawValue,
                "grade": voice.grade,
                "suggested": voice.suggested ? "true" : "false",
                "label": voice.label,
            ])
        }
    }
}
