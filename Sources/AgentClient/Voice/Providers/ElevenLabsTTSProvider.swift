import Foundation
import AVFoundation

/// Streams MP3 audio from the Django voice proxy and plays it through
/// ``AVAudioPlayer``.
///
/// Security: the provider never sees the ElevenLabs API key. It calls
/// ``APIClient.voiceToken()`` to mint a short-lived signed bearer, then
/// POSTs to the proxy's ``ttsUrl`` with that bearer in the Authorization
/// header. Tokens are cached in-memory and refreshed on 401 / near-expiry.
///
/// Latency: each ``speak`` call awaits the full MP3 byte stream before
/// playback starts. The chunker keeps each request short (1-2 sentences)
/// so end-to-end latency stays acceptable on cellular.
public final class ElevenLabsTTSProvider: NSObject, TTSProvider, AVAudioPlayerDelegate {
    public let name = "elevenlabs"

    private let apiClient: APIClient
    private let voiceId: String?
    private let modelId: String?
    private let voiceSettings: [String: Any]?
    private let session: URLSession

    private var cachedToken: VoiceToken?
    private static let refreshLeeway: TimeInterval = 30

    private var currentPlayer: AVAudioPlayer?
    private var currentContinuation: CheckedContinuation<Void, Error>?

    public init(apiClient: APIClient,
                voiceId: String? = nil,
                modelId: String? = nil,
                voiceSettings: [String: Any]? = nil,
                session: URLSession = .shared) {
        self.apiClient = apiClient
        self.voiceId = voiceId
        self.modelId = modelId
        self.voiceSettings = voiceSettings
        self.session = session
    }

    public func speak(_ text: String, options: TTSSpeakOptions) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var (token, ttsUrl) = try await ensureToken()
        var data = try await fetchAudio(text: trimmed, options: options, token: token, ttsUrl: ttsUrl, allowRetry: true)

        // ``allowRetry`` returns nil on 401 to signal "drop the cache and
        // call us again with a fresh token". Mint and retry once.
        if data == nil {
            cachedToken = nil
            (token, ttsUrl) = try await ensureToken()
            data = try await fetchAudio(text: trimmed, options: options, token: token, ttsUrl: ttsUrl, allowRetry: false)
        }
        guard let audioData = data else {
            throw NSError(domain: "ElevenLabsTTSProvider", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Empty audio response"])
        }

        try Task.checkCancellation()
        try await play(audioData: audioData)
    }

    public func cancel() {
        currentPlayer?.stop()
        currentPlayer = nil
        if let cont = currentContinuation {
            currentContinuation = nil
            cont.resume(throwing: CancellationError())
        }
    }

    public func listVoices() async throws -> [VoiceDescriptor] {
        return (try? await apiClient.voices()) ?? []
    }

    // MARK: - HTTP

    private func fetchAudio(text: String, options: TTSSpeakOptions,
                            token: String, ttsUrl: String, allowRetry: Bool) async throws -> Data? {
        guard let url = URL(string: ttsUrl) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try buildBody(text: text, options: options)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 {
            if allowRetry { return nil }
            throw NSError(domain: "ElevenLabsTTSProvider", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "TTS proxy 401 after refresh"])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "ElevenLabsTTSProvider", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS proxy HTTP \(http.statusCode)"])
        }
        return data
    }

    private func buildBody(text: String, options: TTSSpeakOptions) throws -> Data {
        var body: [String: Any] = ["text": text]
        if let v = options.voiceId ?? voiceId { body["voice_id"] = v }
        if let m = options.modelId ?? modelId { body["model_id"] = m }
        if let s = options.voiceSettings ?? voiceSettings { body["voice_settings"] = s }
        if let e = options.emotion {
            var emotionDict: [String: Any] = ["name": e.name, "intensity": e.intensity]
            if !e.metadata.isEmpty { emotionDict["metadata"] = e.metadata }
            body["emotion"] = emotionDict
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Token

    private func ensureToken() async throws -> (String, String) {
        if let cached = cachedToken,
           cached.expiresAt.timeIntervalSinceNow > Self.refreshLeeway {
            return (cached.token, cached.ttsUrl)
        }
        guard let minted = try await apiClient.voiceToken() else {
            throw NSError(domain: "ElevenLabsTTSProvider", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Voice token endpoint returned nothing — is voice enabled on the backend?"])
        }
        cachedToken = minted
        return (minted.token, minted.ttsUrl)
    }

    // MARK: - Playback

    @MainActor
    private func play(audioData: Data) async throws {
        configurePlaybackSession()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            do {
                let player = try AVAudioPlayer(data: audioData)
                player.delegate = self
                self.currentPlayer = player
                self.currentContinuation = cont
                if !player.play() {
                    self.currentContinuation = nil
                    cont.resume(throwing: NSError(domain: "ElevenLabsTTSProvider", code: -3,
                                                  userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer.play() returned false"]))
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Switch the shared audio session into a category that actually
    /// emits sound. The default ``.soloAmbient`` is silenced by the
    /// ring switch, and the mic path puts the session into ``.record``
    /// which forbids playback entirely. ``.playAndRecord`` with
    /// ``.defaultToSpeaker`` is the right fit for a chat-style app
    /// that mixes TTS playback and microphone capture.
    ///
    /// Preserves ``.voiceChat`` mode when set by the input layer for
    /// barge-in (acoustic echo cancellation); otherwise uses
    /// ``.spokenAudio`` for higher-fidelity playback.
    private func configurePlaybackSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            let needsCategoryChange = session.category != .playAndRecord
            let preserveVoiceChat = session.mode == .voiceChat
            if needsCategoryChange || (!preserveVoiceChat && session.mode != .spokenAudio) {
                try session.setCategory(.playAndRecord,
                                        mode: preserveVoiceChat ? .voiceChat : .spokenAudio,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
            }
            try session.setActive(true, options: [])
        } catch {
            #if DEBUG
            print("[ElevenLabsTTSProvider] AVAudioSession setup failed: \(error)")
            #endif
        }
        #endif
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard let cont = currentContinuation else { return }
        currentContinuation = nil
        currentPlayer = nil
        if flag { cont.resume() } else { cont.resume(throwing: CancellationError()) }
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard let cont = currentContinuation else { return }
        currentContinuation = nil
        currentPlayer = nil
        cont.resume(throwing: error ?? NSError(domain: "ElevenLabsTTSProvider", code: -4))
    }
}
