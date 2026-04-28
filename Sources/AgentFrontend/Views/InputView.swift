import SwiftUI
import AVFoundation
import AgentClient
import Speech
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
    @State private var isRecording: Bool = false
    @State private var speechRecognizer = SFSpeechRecognizer()
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    /// Monotonic token so late callbacks from a cancelled/superseded
    /// recognition task cannot repopulate `inputText` after a send/stop.
    /// `SFSpeechRecognitionTask`'s result block can deliver a final
    /// transcription on the main queue *after* `cancel()` returns, which
    /// is the race that caused the input field to refill after submit.
    @State private var recordingSession: Int = 0
    
    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            // Attached files preview
            if !attachedFiles.isEmpty {
                attachedFilesView
            }
            
            // Input row — center alignment keeps icons visually on the text
            // baseline of the pill even though the TextField's padding makes
            // the pill taller than the icons. Matches iMessage/WhatsApp behaviour.
            HStack(alignment: .center, spacing: 8) {
                // File attachment button
                if config.enableFiles {
                    Button(action: { showFilePicker = true }) {
                        Image(systemName: "paperclip")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Voice input button
                if config.enableVoice {
                    Button(action: { toggleRecording() }) {
                        Image(systemName: isRecording ? "mic.fill" : "mic")
                            .font(.title3)
                            .foregroundColor(isRecording ? .red : .secondary)
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
                            .background(Color(hex: "#a85d5d"))
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
        // Invalidate any in-flight recognition callbacks before clearing
        // so a late result cannot rewrite the field. Tear down the audio
        // engine if still recording.
        recordingSession &+= 1
        if isRecording { stopRecording() }
        onSend(inputText, attachedFiles)
        inputText = ""
        attachedFiles = []

        // Dismiss keyboard after sending
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
    
    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else { return }
        
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { return }
            
            DispatchQueue.main.async {
                do {
                    let request = SFSpeechAudioBufferRecognitionRequest()
                    request.shouldReportPartialResults = true
                    self.recognitionRequest = request
                    
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
                    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                    
                    let inputNode = audioEngine.inputNode
                    let recordingFormat = inputNode.outputFormat(forBus: 0)
                    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                        request.append(buffer)
                    }
                    
                    audioEngine.prepare()
                    try audioEngine.start()
                    isRecording = true
                    
                    recordingSession &+= 1
                    let session = recordingSession
                    recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
                        if let result = result {
                            DispatchQueue.main.async {
                                guard self.recordingSession == session else { return }
                                self.inputText = result.bestTranscription.formattedString
                            }
                        }
                        if error != nil || (result?.isFinal == true) {
                            DispatchQueue.main.async {
                                guard self.recordingSession == session else { return }
                                self.stopRecording()
                            }
                        }
                    }
                } catch {
                    stopRecording()
                }
            }
        }
    }
    
    private func stopRecording() {
        // Bump first so any callback that fires between cancel() and the
        // next runloop tick is filtered out by the `session` guard.
        recordingSession &+= 1
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
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

