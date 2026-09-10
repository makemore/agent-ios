import Foundation
import Combine
import AgentClient

/// Presentation-only history state. The view owns the task lifetime; the loader
/// stays injectable so tests need neither a session nor a network connection.
@MainActor
final class SidebarHistoryModel: ObservableObject {
    typealias Loader = @MainActor () async throws -> [Conversation]

    enum Phase: Equatable {
        case idle, loading, loaded, failed, unavailable
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var conversations: [Conversation] = []
    private var requestID = UUID()

    static func clampedLimit(_ limit: Int) -> Int {
        // This sidebar is a bounded preview, not a paginated history browser.
        max(0, min(limit, 100))
    }

    static func displayTitle(for conversation: Conversation) -> String {
        let title = conversation.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled conversation" : title
    }

    func reset() {
        requestID = UUID()
        conversations = []
        phase = .idle
    }

    func load(recentsLimit: Int, using loader: Loader?) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        requestID = request
        conversations = []
        let limit = Self.clampedLimit(recentsLimit)
        guard limit > 0 else {
            phase = .loaded
            return
        }
        guard let loader else {
            phase = .unavailable
            return
        }

        phase = .loading
        do {
            let fetched = try await loader()
            try Task.checkCancellation()
            guard requestID == request else { return }
            conversations = Array(fetched.sorted { lhs, rhs in
                let left = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
                let right = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
                return left == right ? lhs.id < rhs.id : left > right
            }.prefix(limit))
            phase = .loaded
        } catch {
            guard requestID == request else { return }
            // Cancellation is not a server failure, including loaders that use
            // URLSession's cancellation error instead of CancellationError.
            let cancelled = Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled
            phase = cancelled ? .idle : .failed
        }
    }
}