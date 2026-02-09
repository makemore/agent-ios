import SwiftUI

/// Header view with title and action buttons
public struct HeaderView: View {
    let config: ChatWidgetConfig
    @Binding var showSidebar: Bool
    @Binding var selectedTab: ChatTab
    let onClear: () -> Void
    
    private var headerTextColor: Color {
        config.headerTextColor ?? config.primaryColor.contrastingTextColor
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                // Sidebar toggle
                if config.showConversationSidebar {
                    Button(action: { showSidebar.toggle() }) {
                        Image(systemName: "sidebar.left")
                            .font(.title3)
                            .foregroundColor(headerTextColor)
                    }
                }
                
                // Title and subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.title)
                        .font(.headline)
                        .foregroundColor(headerTextColor)
                    if !config.subtitle.isEmpty {
                        Text(config.subtitle)
                            .font(.caption)
                            .foregroundColor(headerTextColor.opacity(0.8))
                    }
                }
                
                Spacer()
                
                // Tab buttons
                if config.showTasksTab {
                    HStack(spacing: 4) {
                        TabButton(
                            title: "Chat",
                            isSelected: selectedTab == .chat,
                            color: headerTextColor
                        ) {
                            selectedTab = .chat
                        }
                        
                        TabButton(
                            title: "Tasks",
                            isSelected: selectedTab == .tasks,
                            color: headerTextColor
                        ) {
                            selectedTab = .tasks
                        }
                    }
                    .padding(.horizontal, 8)
                }
                
                // Clear button
                if config.showClearButton {
                    Button(action: onClear) {
                        Image(systemName: "trash")
                            .font(.title3)
                            .foregroundColor(headerTextColor)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(config.primaryColor)
        }
    }
}

/// Tab button component
struct TabButton: View {
    let title: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color.opacity(0.2) : Color.clear)
                .cornerRadius(12)
                .foregroundColor(color)
        }
    }
}

#if DEBUG
struct HeaderView_Previews: PreviewProvider {
    static var previews: some View {
        HeaderView(
            config: ChatWidgetConfig(),
            showSidebar: .constant(false),
            selectedTab: .constant(.chat),
            onClear: {}
        )
    }
}
#endif

