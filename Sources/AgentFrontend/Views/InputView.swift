import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Message input view with text field and send button
public struct InputView: View {
    let config: ChatWidgetConfig
    let isLoading: Bool
    let onSend: (String, [FileAttachment]) -> Void
    let onCancel: () -> Void
    
    @State private var inputText: String = ""
    @State private var attachedFiles: [FileAttachment] = []
    @State private var showFilePicker: Bool = false
    
    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            // Attached files preview
            if !attachedFiles.isEmpty {
                attachedFilesView
            }
            
            // Input row
            HStack(alignment: .bottom, spacing: 8) {
                // File attachment button
                if config.enableFiles {
                    Button(action: { showFilePicker = true }) {
                        Image(systemName: "paperclip")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Text input
                TextField(config.placeholder, text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(PlatformColors.systemGray6)
                    .cornerRadius(20)
                
                // Send/Cancel button
                if isLoading {
                    Button(action: onCancel) {
                        Image(systemName: "stop.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(canSend ? config.primaryColor : Color.gray)
                            .clipShape(Circle())
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(PlatformColors.systemBackground)
        .sheet(isPresented: $showFilePicker) {
            FilePickerView { files in
                attachedFiles.append(contentsOf: files)
            }
        }
    }
    
    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedFiles.isEmpty
    }
    
    private func sendMessage() {
        guard canSend else { return }
        onSend(inputText, attachedFiles)
        inputText = ""
        attachedFiles = []
    }
    
    @ViewBuilder
    private var attachedFilesView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachedFiles) { file in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.fill")
                            .font(.caption)
                        Text(file.name)
                            .font(.caption)
                            .lineLimit(1)
                        Button(action: { removeFile(file) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(PlatformColors.systemGray5)
                    .cornerRadius(12)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
    
    private func removeFile(_ file: FileAttachment) {
        attachedFiles.removeAll { $0.id == file.id }
    }
}

/// Simple file picker placeholder
struct FilePickerView: View {
    let onSelect: ([FileAttachment]) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                Text("File picker not implemented")
                    .foregroundColor(.secondary)
                Text("Use DocumentPicker for production")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Select Files")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

