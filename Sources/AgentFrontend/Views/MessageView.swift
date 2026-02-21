import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Individual message view
public struct MessageView: View {
    let message: Message
    let config: ChatWidgetConfig
    let showDebug: Bool
    let onRetry: (() -> Void)?
    let onEdit: (() -> Void)?
    
    private var isUser: Bool { message.role == .user }
    private var isSystem: Bool { message.role == .system }
    private var isToolMessage: Bool { message.type == .toolCall || message.type == .toolResult }
    
    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Message bubble with long-press copy
                messageBubble
                    .contextMenu {
                        Button {
                            #if os(iOS)
                            UIPasteboard.general.string = message.content
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            #endif
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }

                        if let onRetry = onRetry {
                            Button {
                                onRetry()
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                        }

                        if let onEdit = onEdit {
                            Button {
                                onEdit()
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                        }
                    }

                // Actions row
                if !isSystem && !isToolMessage {
                    actionsRow
                }
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }
    
    @ViewBuilder
    private var messageBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tool/system message header
            if isToolMessage || isSystem {
                HStack(spacing: 4) {
                    messageIcon
                    if let toolName = message.metadata?.toolName {
                        Text(toolName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }
            
            // Content
            Text(message.content)
                .font(.body)
                .foregroundColor(messageTextColor)
            
            // Debug info
            if showDebug, let metadata = message.metadata {
                debugInfo(metadata)
            }
            
            // File attachments
            if let files = message.files, !files.isEmpty {
                fileAttachments(files)
            }
        }
        .padding(12)
        .background(bubbleBackground)
        .cornerRadius(16)
    }
    
    @ViewBuilder
    private var messageIcon: some View {
        switch message.type {
        case .toolCall:
            Image(systemName: "wrench.fill")
                .foregroundColor(.orange)
        case .toolResult:
            Image(systemName: message.content.contains("❌") ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundColor(message.content.contains("❌") ? .red : .green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundColor(.orange)
        case .subAgentStart, .subAgentEnd, .agentContext:
            Image(systemName: "link")
                .foregroundColor(.blue)
        default:
            EmptyView()
        }
    }
    
    private var messageTextColor: Color {
        if isUser {
            return config.primaryColor.contrastingTextColor
        }
        return .primary
    }
    
    private var bubbleBackground: Color {
        if isUser {
            return config.primaryColor
        }
        if isToolMessage || isSystem {
            return PlatformColors.systemGray6
        }
        return PlatformColors.systemGray5
    }
    
    @ViewBuilder
    private var actionsRow: some View {
        HStack(spacing: 12) {
            if let onRetry = onRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            
            if let onEdit = onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            
            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private func debugInfo(_ metadata: MessageMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let args = metadata.arguments {
                Text("Args: \(args)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.top, 4)
    }
    
    @ViewBuilder
    private func fileAttachments(_ files: [FileAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(files) { file in
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                        .font(.caption)
                    Text(file.name)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundColor(.secondary)
            }
        }
    }
}

