import SwiftUI

/// Readable-width cap for chat surfaces on wide layouts (iPad, landscape,
/// Split View, Stage Manager). Applied to the message list content and the
/// composer with the same width so the two columns stay aligned. Keys off
/// available width, never device idiom, so arbitrary window sizes behave the
/// same as full screen. No-op at iPhone widths.
extension View {
    func chatReadableColumn(maxWidth: CGFloat = 720) -> some View {
        self
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}
