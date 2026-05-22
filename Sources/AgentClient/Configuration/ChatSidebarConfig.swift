import Foundation
import SwiftUI

/// Static nav entry shown in the chat sidebar above "Recents". The
/// library ships a default set (Chats, Projects, Artifacts, Code,
/// Dispatch) but host apps can supply their own list — every item is
/// rendered as a plain icon + label row with the supplied handler
/// invoked on tap.
public struct SidebarItem: Identifiable, Hashable {
    public let id: String
    /// SF Symbol name. Drawn at title3 size with the appearance's
    /// secondary text colour.
    public let systemImage: String
    /// Row label.
    public let title: String
    /// Optional trailing badge text (e.g. "New").
    public let badge: String?
    /// Tap handler. Wrapped in a private closure so `SidebarItem`
    /// can stay `Hashable` for use as a `ForEach` id.
    private let _action: () -> Void

    public init(
        id: String,
        systemImage: String,
        title: String,
        badge: String? = nil,
        action: @escaping () -> Void = {}
    ) {
        self.id = id
        self.systemImage = systemImage
        self.title = title
        self.badge = badge
        self._action = action
    }

    public func perform() { _action() }

    public static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool {
        lhs.id == rhs.id && lhs.systemImage == rhs.systemImage
            && lhs.title == rhs.title && lhs.badge == rhs.badge
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(systemImage)
        hasher.combine(title)
        hasher.combine(badge)
    }
}

/// Controls the slide-in conversation sidebar shown by the bundled
/// `ChatWidgetView`. Disabled by default in this data type so existing
/// consumers see no change; the library's bundled widget opts in for
/// its new warm-dark baseline.
public struct ChatSidebarConfig {
    /// When `true`, `ChatWidgetView` renders a hamburger button in
    /// its top bar that toggles a slide-in panel. When `false` the
    /// widget renders exactly as in 0.7.x.
    public var enabled: Bool

    /// Brand wordmark rendered at the top of the panel. Empty string
    /// hides the wordmark.
    public var wordmark: String

    /// Static nav items rendered above the "Recents" section. Host
    /// apps override this to integrate their own destinations. The
    /// library default ships a small "Chats / Projects / Artifacts /
    /// Code / Dispatch" set as a starting point.
    public var items: [SidebarItem]

    /// Section heading for the dynamic conversation list. Set to
    /// empty string to suppress the heading.
    public var recentsTitle: String

    /// When `true`, the panel queries `APIClient.loadConversations`
    /// on appear and renders one row per result. When `false` the
    /// recents section is suppressed (useful for hosts that supply
    /// their own conversation list via `items`).
    public var showRecents: Bool

    /// Maximum recents to fetch / render. Conversations beyond this
    /// are dropped; the panel does not paginate.
    public var recentsLimit: Int

    /// Initials shown in the footer avatar (e.g. "CB"). When nil the
    /// avatar circle is rendered without text.
    public var footerInitials: String?

    /// Footer caption shown next to the avatar (e.g. user's full
    /// name or plan tier).
    public var footerCaption: String?

    /// Label for the footer's primary "New chat" pill. Set to empty
    /// string to hide the button.
    public var newChatLabel: String

    public init(
        enabled: Bool = false,
        wordmark: String = "S'Ai",
        items: [SidebarItem] = ChatSidebarConfig.defaultItems,
        recentsTitle: String = "Recents",
        showRecents: Bool = true,
        recentsLimit: Int = 30,
        footerInitials: String? = nil,
        footerCaption: String? = nil,
        newChatLabel: String = "New chat"
    ) {
        self.enabled = enabled
        self.wordmark = wordmark
        self.items = items
        self.recentsTitle = recentsTitle
        self.showRecents = showRecents
        self.recentsLimit = recentsLimit
        self.footerInitials = footerInitials
        self.footerCaption = footerCaption
        self.newChatLabel = newChatLabel
    }

    /// Starter rows shipped with the library. Action defaults to a
    /// no-op; host apps replace the list to wire real destinations.
    public static var defaultItems: [SidebarItem] {
        [
            SidebarItem(id: "chats",     systemImage: "bubble.left",            title: "Chats"),
            SidebarItem(id: "projects",  systemImage: "folder",                 title: "Projects"),
            SidebarItem(id: "artifacts", systemImage: "square.stack.3d.up",     title: "Artifacts"),
            SidebarItem(id: "code",      systemImage: "chevron.left.forwardslash.chevron.right", title: "Code"),
            SidebarItem(id: "dispatch",  systemImage: "paperplane",             title: "Dispatch"),
        ]
    }
}
