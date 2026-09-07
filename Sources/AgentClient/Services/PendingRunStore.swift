import Foundation
import CryptoKit

enum PendingRunFailure: LocalizedError {
    case storageUnavailable, identityUnavailable, expired, unavailable, invalidStatus, pendingConflict
    var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "Cannot securely save reply recovery data. Unlock the device and retry."
        case .identityUnavailable: return "Sign in before recovering or sending a message."
        case .expired: return "This pending reply has expired and cannot be recovered."
        case .unavailable: return "This reply is no longer available. It was not sent again."
        case .invalidStatus: return "The server returned an unsupported run state."
        case .pendingConflict: return "Another reply is pending for this chat. Recover it before sending again."
        }
    }
}

struct PendingRun: Codable {
    let scope: String
    var ownerScope: String? = nil
    let idempotencyKey: String
    let body: Data
    let createdAt: Date
    var runId: String?
    var conversationId: String?
    var waiting: Bool = false
    var retryCount: Int = 0
    var nextRetryAt: Date?
    // No event cursor is persisted. Reconstruction replays from zero and
    // suppresses external actions/TTS for the entire recovered turn.
    var transcript: [PendingMessage]
    // The replay base must stay separate from the waiting UI; otherwise a
    // resumed run would duplicate tools/actions already in its SSE replay.
    var waitingTranscript: [PendingMessage]? = nil
    var messagesOffset: Int
    var nextBeforeSeq: Int?
    var hasMore: Bool

    var mayRetryCreation: Bool { Date().timeIntervalSince(createdAt) < 24 * 60 * 60 }
}

/// Restorable UI base, including rich/tool rows. The original request body is
/// stored separately and remains the source of truth for ephemeral context.
struct PendingMessage: Codable {
    let message: LocalMessage
    let blocks: [ContentBlock]?
    let toolName: String?
    let toolCallId: String?
    let arguments: String?
    let result: AnyCodable?
    let subAgentKey: String?
    let agentName: String?
    let invocationMode: String?
    let actionId: String?
    let actionType: String?
    let actionURL: String?
    let actionLabel: String?
    let resumeHint: AnyCodable?
    let subAgentDurationSeconds: Double?
    let files: [FileAttachment]?

    init(from source: Message) {
        message = LocalMessage(from: source)
        let m = source.metadata
        blocks = m?.contentBlocks
        toolName = m?.toolName
        toolCallId = m?.toolCallId
        arguments = m?.arguments
        result = Self.json(m?.result)
        subAgentKey = m?.subAgentKey
        agentName = m?.agentName
        invocationMode = m?.invocationMode
        actionId = m?.actionId
        actionType = m?.actionType
        actionURL = m?.actionURL
        actionLabel = m?.actionLabel
        resumeHint = Self.json(m?.resumeHint)
        subAgentDurationSeconds = m?.subAgentDurationSeconds
        files = source.files
    }

    private static func json(_ value: Any?) -> AnyCodable? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONDecoder().decode(AnyCodable.self, from: data)
    }

    private static func value(_ json: AnyCodable?) -> Any? {
        guard let json, let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    func toMessage() -> Message {
        var restored = message.toMessage()
        restored.metadata = MessageMetadata(toolName: toolName, toolCallId: toolCallId,
            arguments: arguments, result: Self.value(result), subAgentKey: subAgentKey,
            agentName: agentName, invocationMode: invocationMode, contentBlocks: blocks,
            actionId: actionId, actionType: actionType, actionURL: actionURL, actionLabel: actionLabel,
            resumeHint: Self.value(resumeHint), subAgentDurationSeconds: subAgentDurationSeconds)
        restored.files = files
        return restored
    }
}

/// Pending request content must NEVER fall back to UserDefaults. The injectable
/// storage is for tests; production always uses the device-only Keychain.
final class PendingRunStore {
    private static let lock = NSRecursiveLock()
    private let storage: StorageService
    init(storage: StorageService = KeychainStorage(service: "com.makemore.agent.pending-runs")) {
        self.storage = storage
    }

    static func scope(backend: String, agent: String, principal: String) -> String {
        let fields = [backend.trimmingCharacters(in: CharacterSet(charactersIn: "/")), agent, principal]
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func load(scope: String) -> PendingRun? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let text = storage.get("pending_run_\(scope)"), let data = text.data(using: .utf8),
              let run = try? JSONDecoder().decode(PendingRun.self, from: data), run.scope == scope else { return nil }
        return run
    }

    func save(_ run: PendingRun) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let existing = load(scope: run.scope), existing.idempotencyKey != run.idempotencyKey {
            throw PendingRunFailure.pendingConflict
        }
        // Index first: a crash may leave an empty index entry, never an
        // undiscoverable transcript that logout/privacy purge cannot remove.
        if let owner = run.ownerScope {
            let indexKey = "pending_run_index_\(owner)"
            var scopes = indexedScopes(owner: owner)
            if !scopes.contains(run.scope) { scopes.append(run.scope) }
            let index = String(decoding: try JSONEncoder().encode(scopes), as: UTF8.self)
            storage.set(indexKey, value: index)
            guard storage.get(indexKey) == index else { throw PendingRunFailure.storageUnavailable }
        }
        let data = try JSONEncoder().encode(run)
        guard let text = String(data: data, encoding: .utf8) else { throw PendingRunFailure.storageUnavailable }
        let key = "pending_run_\(run.scope)"
        storage.set(key, value: text)
        // StorageService predates throwing writes. Read-back makes a failed
        // Keychain write fail closed BEFORE POST rather than losing identity.
        guard storage.get(key) == text else { throw PendingRunFailure.storageUnavailable }
    }

    func clear(scope: String, matching key: String? = nil) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let key, load(scope: scope)?.idempotencyKey != key { return }
        storage.set("pending_run_\(scope)", value: nil)
    }

    private func indexedScopes(owner: String) -> [String] {
        guard let text = storage.get("pending_run_index_\(owner)") else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }

    func clearAll(owner: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        for scope in indexedScopes(owner: owner) { clear(scope: scope) }
        storage.set("pending_run_index_\(owner)", value: nil)
    }
}