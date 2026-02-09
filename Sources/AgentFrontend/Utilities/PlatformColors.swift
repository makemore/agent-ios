import SwiftUI

/// Cross-platform color definitions
public enum PlatformColors {
    /// System background color
    public static var systemBackground: Color {
        #if os(iOS)
        return Color(UIColor.systemBackground)
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }
    
    /// Secondary system background
    public static var secondarySystemBackground: Color {
        #if os(iOS)
        return Color(UIColor.secondarySystemBackground)
        #else
        return Color(NSColor.controlBackgroundColor)
        #endif
    }
    
    /// System gray 5
    public static var systemGray5: Color {
        #if os(iOS)
        return Color(UIColor.systemGray5)
        #else
        return Color(NSColor.systemGray).opacity(0.3)
        #endif
    }
    
    /// System gray 6
    public static var systemGray6: Color {
        #if os(iOS)
        return Color(UIColor.systemGray6)
        #else
        return Color(NSColor.systemGray).opacity(0.2)
        #endif
    }
}

#if os(iOS)
import UIKit
#else
import AppKit
#endif

