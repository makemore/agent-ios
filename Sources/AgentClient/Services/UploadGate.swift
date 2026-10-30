import Foundation

/// Lets at most `limit` uploads run at once; the rest wait in order. A waiting upload that
/// is cancelled leaves the line without taking a place.
actor UploadGate {
    private let limit: Int
    private var active = 0
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await wait(id)
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Give back a place taken with ``acquire()``.
    func release() {
        while let id = order.first {
            order.removeFirst()
            if let waiter = waiters.removeValue(forKey: id) {
                waiter.resume()  // The place passes straight on.
                return
            }
        }
        active = max(0, active - 1)
    }

    private func wait(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters[id] = continuation
            order.append(id)
        }
    }

    private func cancel(_ id: UUID) {
        order.removeAll { $0 == id }
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
