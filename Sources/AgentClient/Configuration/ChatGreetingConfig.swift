import Foundation

/// Controls the empty-state greeting shown when the conversation has
/// no messages yet (e.g. "Good afternoon, Chris"). Disabled-by-default
/// in the data model so direct consumers of `MessageListView` see no
/// behavioural change unless they opt in via
/// `ChatWidgetConfig.greeting.enabled = true`, but the bundled
/// `ChatWidgetView` enables it by default to match the library's new
/// warm-dark baseline.
public struct ChatGreetingConfig {
    /// When `true`, the empty state renders the optional brand mark +
    /// serif greeting instead of the legacy speech-bubble icon.
    public var enabled: Bool

    /// Display name used in the greeting (e.g. "Chris" →
    /// "Good afternoon, Chris"). When `nil` or empty the greeting
    /// drops the trailing comma + name and renders only the
    /// time-of-day phrase. Host apps typically wire this to the
    /// signed-in user's first name.
    public var userName: String?

    /// Greeting copy keyed by time of day. The view picks the entry
    /// matching the device's current hour using `phase(forHour:)`.
    /// Override individual strings to localise without subclassing
    /// the view.
    public var morningTemplate: String
    public var afternoonTemplate: String
    public var eveningTemplate: String
    public var nightTemplate: String

    public init(
        enabled: Bool = false,
        userName: String? = nil,
        morningTemplate: String = "Good morning",
        afternoonTemplate: String = "Good afternoon",
        eveningTemplate: String = "Good evening",
        nightTemplate: String = "Good evening"
    ) {
        self.enabled = enabled
        self.userName = userName
        self.morningTemplate = morningTemplate
        self.afternoonTemplate = afternoonTemplate
        self.eveningTemplate = eveningTemplate
        self.nightTemplate = nightTemplate
    }

    /// Returns the greeting line for an hour-of-day in 0..<24,
    /// appending ", \(userName)" when set. The split is the standard
    /// Western "morning until noon / afternoon until 5pm / evening
    /// until 10pm / late night" carve-up.
    public func line(forHour hour: Int) -> String {
        let phase: String
        switch hour {
        case 5..<12:  phase = morningTemplate
        case 12..<17: phase = afternoonTemplate
        case 17..<22: phase = eveningTemplate
        default:      phase = nightTemplate
        }
        if let name = userName, !name.isEmpty {
            return "\(phase), \(name)"
        }
        return phase
    }

    /// Convenience: the greeting line for "now". Pulled into a
    /// separate method so tests can drive a deterministic hour.
    public func currentLine(calendar: Calendar = .current, now: Date = Date()) -> String {
        let hour = calendar.component(.hour, from: now)
        return line(forHour: hour)
    }
}
