import Foundation
import AVFoundation

/// On-device TTS provider built on ``AVSpeechSynthesizer``.
///
/// Free, no backend round-trip. Used as a fallback when no ElevenLabs
/// proxy is configured. Voice quality varies by OS version and the
/// user's installed enhanced voices.
///
/// Implements the same surface as ``ElevenLabsTTSProvider`` so the
/// controller can swap them transparently.
public final class AVSpeechTTSProvider: NSObject, TTSProvider, AVSpeechSynthesizerDelegate {
    public let name = "av-speech"

    private let synthesizer = AVSpeechSynthesizer()
    private let voiceIdentifier: String?
    private let baseRate: Float
    private let basePitch: Float
    private let baseVolume: Float

    private var currentContinuation: CheckedContinuation<Void, Error>?
    private var currentUtterance: AVSpeechUtterance?

    public init(voiceIdentifier: String? = nil,
                rate: Float = AVSpeechUtteranceDefaultSpeechRate,
                pitch: Float = 1.0,
                volume: Float = 1.0) {
        self.voiceIdentifier = voiceIdentifier
        self.baseRate = rate
        self.basePitch = pitch
        self.baseVolume = volume
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String, options: TTSSpeakOptions) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any prior utterance up-front so two `speak` calls in
        // quick succession don't stack on the synthesizer queue.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = baseRate
        utterance.pitchMultiplier = basePitch
        utterance.volume = baseVolume

        let voiceId = options.voiceId ?? voiceIdentifier
        if let voiceId = voiceId, let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }

        applyEmotion(options.emotion, to: utterance)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Cancellation handler — Task.cancel() bridges into stop().
            self.currentContinuation = cont
            self.currentUtterance = utterance
            if Task.isCancelled {
                self.resumeWith(error: CancellationError())
                return
            }
            self.synthesizer.speak(utterance)
        }
    }

    public func cancel() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // didCancel delegate will resume the continuation if one is in flight.
    }

    public func listVoices() async throws -> [VoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            VoiceDescriptor(id: v.identifier, name: v.name, labels: [
                "lang": v.language,
                "quality": v.quality == .enhanced ? "enhanced" : "default",
            ])
        }
    }

    // MARK: - Emotion mapping

    /// Coarse mapping — bigger pitch + slight rate bump for upbeat
    /// emotions, calmer + slower for downbeat. AVSpeech doesn't expose
    /// anything richer than rate/pitch/volume.
    private func applyEmotion(_ emotion: Emotion?, to utterance: AVSpeechUtterance) {
        guard let emotion = emotion else { return }
        let i = Float(emotion.intensity)
        switch emotion.name.lowercased() {
        case "happy", "excited":
            utterance.pitchMultiplier = clamp(basePitch + 0.3 * i, 0.5, 2.0)
            utterance.rate = clamp(baseRate + 0.05 * i, AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceMaximumSpeechRate)
        case "sad", "concerned":
            utterance.pitchMultiplier = clamp(basePitch - 0.2 * i, 0.5, 2.0)
            utterance.rate = clamp(baseRate - 0.05 * i, AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceMaximumSpeechRate)
        case "angry":
            utterance.pitchMultiplier = clamp(basePitch - 0.1 * i, 0.5, 2.0)
            utterance.volume = clamp(baseVolume + 0.1 * i, 0.0, 1.0)
        default:
            break
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        resumeWith(error: nil)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        resumeWith(error: CancellationError())
    }

    private func resumeWith(error: Error?) {
        guard let cont = currentContinuation else { return }
        currentContinuation = nil
        currentUtterance = nil
        if let error = error { cont.resume(throwing: error) } else { cont.resume() }
    }

    private func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        return max(lo, min(hi, v))
    }
}
