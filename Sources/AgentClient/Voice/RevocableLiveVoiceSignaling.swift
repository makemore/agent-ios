import Foundation

/// A single-use create capability. Revocation never disables cleanup/status and
/// never swaps the original adapter, even when a POST ignores cancellation.
@MainActor
final class RevocableLiveVoiceSignaling: LiveVoiceSignaling {
    private let signaling: any LiveVoiceSignaling
    private var revoked = false
    private var createAttempted = false
    private var closeTasks: [String: Task<Void, Error>] = [:]

    init(signaling: any LiveVoiceSignaling) { self.signaling = signaling }

    func revoke() { revoked = true }

    func createLiveSession(sdp: String, conversationId: String?) async throws -> LiveSessionResponse {
        try Task.checkCancellation()
        guard !revoked, !createAttempted else { throw CancellationError() }
        createAttempted = true
        let result = try await signaling.createLiveSession(sdp: sdp, conversationId: conversationId)
        guard !revoked, !Task.isCancelled else {
            // An independent task is not canceled with the POST's caller. Do
            // not return the SDP or hold up local teardown waiting for cleanup.
            Task { try? await self.closeLiveSession(id: result.id) }
            throw CancellationError()
        }
        return result
    }

    /// Coalesce concurrent/repeated cleanup, including failed requests, so a
    /// late POST, explicit end, and disposal cannot each send their own close.
    func closeLiveSession(id: String) async throws {
        if let task = closeTasks[id] { return try await task.value }
        let task = Task { [signaling] in try await signaling.closeLiveSession(id: id) }
        closeTasks[id] = task
        try await task.value
    }

    func liveSessionStatus(id: String) async throws -> LiveSessionStatus {
        try await signaling.liveSessionStatus(id: id)
    }
}