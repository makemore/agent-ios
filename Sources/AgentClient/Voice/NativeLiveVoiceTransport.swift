#if os(iOS) && canImport(WebRTC)
import AVFoundation
import Foundation
import WebRTC

/// One peer and one native VoiceProcessingIO audio device per explicit attempt.
/// The adapter never handles PCM or contacts the application server.
@MainActor
final class NativeLiveVoiceTransport: LiveVoiceTransport {
    private static let sslReady = RTCInitializeSSL()
    var onEvent: ((LiveVoiceTransportEvent) -> Void)?
    private var factory: RTCPeerConnectionFactory?
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var microphone: RTCAudioTrack?
    private var closed = false
    private var mediaStopped = false
    private var ownsAudio = false
    private var activatedAudio = false
    private var callKitAudioLease: UUID?
    private var previousManualAudio = false
    private var previousAudioEnabled = false
    private var previousPreferredErrorsIgnored = false
    private var previousRTCConfiguration: RTCAudioSessionConfiguration?
    private var offerContinuation: CheckedContinuation<RTCSessionDescription, Error>?
    private var descriptionContinuation: CheckedContinuation<Void, Error>?
    private var descriptionGeneration = UUID()
    private var statsTask: Task<Void, Never>?
    private var statsRequest: UUID?
    private var statsRequestedAt = Date.distantPast
    private var meter = LiveVoiceAudioMeter()
    private lazy var delegate = LiveRTCDelegate { [weak self] event in
        guard let self, !self.closed else { return }
        switch event {
        case .message(let data): self.onEvent?(.message(data))
        case .disconnected: self.onEvent?(.disconnected)
        case .track(let track):
            // A receiver callback may have been queued before end().
            track.isEnabled = !self.mediaStopped
        }
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    func makeOffer() async throws -> String {
        guard !closed, peer == nil, onEvent != nil, Self.sslReady else { throw LiveVoiceError.connectionFailed }
        try claimAudio()
        let factory = RTCPeerConnectionFactory()
        self.factory = factory
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: delegate) else {
            throw LiveVoiceError.connectionFailed
        }
        self.peer = peer
        // VoiceProcessingIO + voiceChat supply acoustic echo cancellation;
        // WebRTC also enables its standard echo/noise processing on the source.
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil,
            optionalConstraints: ["googEchoCancellation": "true", "googNoiseSuppression": "true"]))
        let microphone = factory.audioTrack(with: source, trackId: "live-microphone")
        self.microphone = microphone
        guard peer.add(microphone, streamIds: ["live-audio"]) != nil,
              let channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()) else {
            throw LiveVoiceError.connectionFailed
        }
        self.channel = channel
        channel.delegate = delegate
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            offerContinuation = continuation
            peer.offer(for: constraints) { [weak self] sdp, error in
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, let pending = self.offerContinuation else { return }
                    self.offerContinuation = nil
                    if let sdp, error == nil { pending.resume(returning: sdp) }
                    else { pending.resume(throwing: LiveVoiceError.connectionFailed) }
                }
            }
        }
        try checkOpen()
        try await setDescription(offer, local: true)
        // No trickle ICE endpoint. Read the final localDescription, not the
        // original offer, after bounded gathering of all local candidates.
        for _ in 0..<100 {
            try checkOpen()
            if peer.iceGatheringState == .complete {
                guard let sdp = peer.localDescription?.sdp, !sdp.isEmpty else { throw LiveVoiceError.connectionFailed }
                return sdp
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LiveVoiceError.connectionFailed
    }

    func acceptAnswer(_ sdp: String) async throws {
        try checkOpen()
        try await setDescription(RTCSessionDescription(type: .answer, sdp: sdp), local: false)
        try checkOpen()
        guard !mediaStopped, ownsAudio else { throw CancellationError() }
        if let callKitAudioLease {
            // Activation can precede or follow SDP. Never wait for audio here:
            // session.started arrives over the independently running data channel.
            LiveVoiceCallKitAudio.setMediaReady(true, for: callKitAudioLease)
        } else {
            RTCAudioSession.sharedInstance().isAudioEnabled = true
        }
        startStats()
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        guard !closed, !mediaStopped else { return }
        microphone?.isEnabled = enabled
    }

    @discardableResult
    func send(_ command: LiveVoiceCommand, eventId: String) -> Bool {
        guard !closed, let channel, channel.readyState == .open,
              let data = try? JSONEncoder().encode(["type": command.rawValue, "event_id": eventId]) else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    func stopMedia() {
        guard !mediaStopped else { return }
        mediaStopped = true
        microphone?.isEnabled = false
        peer?.receivers.forEach { $0.track?.isEnabled = false }
        statsTask?.cancel()
        statsTask = nil
        statsRequest = nil
        if ownsAudio {
            // Stops and uninitializes both capture and playout immediately,
            // while SCTP/DTLS can continue receiving the final usage event.
            if let callKitAudioLease {
                LiveVoiceCallKitAudio.setMediaReady(false, for: callKitAudioLease)
            } else {
                RTCAudioSession.sharedInstance().isAudioEnabled = false
            }
        }
        onEvent?(.levels(input: 0, output: 0))
    }

    func close() {
        guard !closed else { return }
        stopMedia()
        closed = true
        onEvent = nil
        channel?.delegate = nil
        channel?.close()
        channel = nil
        peer?.delegate = nil
        peer?.close()
        peer = nil
        microphone = nil
        factory = nil
        offerContinuation?.resume(throwing: CancellationError())
        offerContinuation = nil
        descriptionContinuation?.resume(throwing: CancellationError())
        descriptionContinuation = nil
        releaseAudio()
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        if closed || mediaStopped { throw CancellationError() }
    }

    private func setDescription(_ description: RTCSessionDescription, local: Bool) async throws {
        try checkOpen()
        guard let peer else { throw LiveVoiceError.connectionFailed }
        let token = UUID()
        descriptionGeneration = token
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            descriptionContinuation = continuation
            let completion: (Error?) -> Void = { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.descriptionGeneration == token,
                          let pending = self.descriptionContinuation else { return }
                    self.descriptionContinuation = nil
                    if error == nil { pending.resume() }
                    else { pending.resume(throwing: LiveVoiceError.connectionFailed) }
                }
            }
            if local { peer.setLocalDescription(description, completionHandler: completion) }
            else { peer.setRemoteDescription(description, completionHandler: completion) }
        }
    }

    private func claimAudio() throws {
        if LiveVoiceCallKitAudio.isPrepared {
            guard let lease = LiveVoiceCallKitAudio.claim() else { throw LiveVoiceError.unavailable }
            callKitAudioLease = lease
        } else {
            guard AudioSessionCoordinator.owner == .unclaimed else { throw LiveVoiceError.unavailable }
            AudioSessionCoordinator.owner = .liveVoice
        }
        ownsAudio = true
        let audio = RTCAudioSession.sharedInstance()
        if callKitAudioLease == nil {
            previousManualAudio = audio.useManualAudio
            previousAudioEnabled = audio.isAudioEnabled
        }
        previousPreferredErrorsIgnored = audio.ignoresPreferredAttributeConfigurationErrors
        previousRTCConfiguration = RTCAudioSessionConfiguration.webRTC()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        let configuration = RTCAudioSessionConfiguration()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        configuration.categoryOptions = [.defaultToSpeaker, .allowBluetooth]
        // The native audio device reapplies this configuration when it starts.
        // Without this, its defaults can undo our speaker/voiceChat selection.
        RTCAudioSessionConfiguration.setWebRTC(configuration)
        audio.ignoresPreferredAttributeConfigurationErrors = true
        try audio.setConfiguration(configuration)
        if callKitAudioLease == nil {
            try audio.setActive(true)
            activatedAudio = true
        }
    }

    private func releaseAudio() {
        guard ownsAudio else { return }
        ownsAudio = false
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        if activatedAudio { try? audio.setActive(false) }
        activatedAudio = false
        if let previousRTCConfiguration { RTCAudioSessionConfiguration.setWebRTC(previousRTCConfiguration) }
        previousRTCConfiguration = nil
        audio.ignoresPreferredAttributeConfigurationErrors = previousPreferredErrorsIgnored
        // All of our peers/tracks are gone before restoring the manual gate.
        if callKitAudioLease == nil {
            audio.isAudioEnabled = previousAudioEnabled
            audio.useManualAudio = previousManualAudio
        }
        audio.unlockForConfiguration()
        if let callKitAudioLease {
            LiveVoiceCallKitAudio.release(callKitAudioLease)
            self.callKitAudioLease = nil
        } else if AudioSessionCoordinator.owner == .liveVoice {
            AudioSessionCoordinator.owner = .unclaimed
        }
    }

    private func startStats() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollStats()
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
        }
    }

    private func pollStats() {
        guard !closed, !mediaStopped, let peer else { return }
        if statsRequest != nil {
            // Missing reports are unknown/silent, never sustained speech.
            if Date().timeIntervalSince(statsRequestedAt) > 1 { onEvent?(.levels(input: 0, output: 0)) }
            return
        }
        let token = UUID()
        statsRequest = token
        statsRequestedAt = Date()
        peer.statistics { [weak self] report in
            Task { @MainActor [weak self] in
                guard let self, !self.closed, !self.mediaStopped, self.statsRequest == token else { return }
                self.statsRequest = nil
                let samples = report.statistics.values.map {
                    LiveVoiceAudioMeter.Sample(id: $0.id, type: $0.type, values: $0.values)
                }
                let levels = self.meter.levels(samples)
                self.onEvent?(.levels(input: self.microphone?.isEnabled == true ? levels.input : 0, output: levels.output))
            }
        }
    }
}

/// Objective-C delegates run on WebRTC threads. Only copied events cross to
/// the main actor, whose single-use adapter discards callbacks after close.
private final class LiveRTCDelegate: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    enum Event { case message(Data), disconnected, track(RTCMediaStreamTrack) }
    private let deliver: @MainActor (Event) -> Void
    init(deliver: @escaping @MainActor (Event) -> Void) { self.deliver = deliver }
    private func emit(_ event: Event) {
        // Preserve the data channel's delivery order when hopping executors.
        DispatchQueue.main.async { [deliver] in deliver(event) }
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed { emit(.disconnected) }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, buffer.data.count <= 262_144 else { return }
        emit(.message(buffer.data))
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .disconnected || newState == .failed || newState == .closed { emit(.disconnected) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        if newState == .disconnected || newState == .failed || newState == .closed { emit(.disconnected) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Only the locally-created oai-events channel is used.
        dataChannel.close()
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let track = rtpReceiver.track { emit(.track(track)) }
    }
}
#endif