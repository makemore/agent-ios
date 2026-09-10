import XCTest
@testable import AgentClient

@MainActor
final class ConversationLoadingTests: XCTestCase {
    private var config: ChatWidgetConfig!
    private var storage: InMemoryStorage!
    private var api: APIClient!
    private var model: ChatViewModel!
    private var tasks: [Task<Void, Never>] = []

    override func setUp() {
        super.setUp()
        APIClient.sessionConfigurator = { $0.protocolClasses = [ControlledHistoryURLProtocol.self] }
        config = ChatWidgetConfig(backendUrl: "https://example.test", agentKey: "conversation-loading-tests")
        config.authStrategy = .token
        config.authToken = "synthetic-history-owner"
        storage = InMemoryStorage()
        makeModel()
    }

    override func tearDown() {
        model.invalidateForReplacement()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        api.session.invalidateAndCancel()
        ControlledHistoryURLProtocol.onRequest = nil
        APIClient.sessionConfigurator = nil
        super.tearDown()
    }

    func testSuccessCommitsOnlyAfterResponseAndResetsConversationState() async throws {
        try await loadOldConversation()
        let oldIDs = model.messages.map(\.id)
        var applied = false
        let load = try await begin { applied = await self.model.loadConversation("new") }

        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.conversationId, "old")
        XCTAssertEqual(storage.get(config.conversationIdKey), "old")
        XCTAssertEqual(model.messages.map(\.id), oldIDs)
        XCTAssertTrue(model.extendedThinking)
        XCTAssertTrue(model.subAgentActivity.isActive)
        XCTAssertEqual(model.contextTokens, 123)

        load.request.respond(body: #"{"id":"new","messages":[{"seq":10,"role":"user","content":"New question"},{"seq":11,"role":"assistant","content":"New answer"}],"has_more":true,"next_before_seq":10,"metadata":{"last_context_usage":{"total_tokens":456,"context_window":8192,"model_id":"new-model"}}}"#)
        await fulfillment(of: [load.finished], timeout: 2)

        XCTAssertTrue(applied)
        XCTAssertEqual(model.conversationId, "new")
        XCTAssertEqual(storage.get(config.conversationIdKey), "new")
        XCTAssertEqual(model.messages.map(\.id), ["message-seq-new-10", "message-seq-new-11"])
        XCTAssertEqual(model.messages.map(\.content), ["New question", "New answer"])
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.loadingMoreMessages)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.runState, .idle)
        XCTAssertFalse(model.extendedThinking)
        XCTAssertFalse(model.subAgentActivity.isActive)
        XCTAssertEqual(model.contextTokens, 456)
        XCTAssertEqual(model.contextWindow, 8192)
        XCTAssertEqual(model.contextModelId, "new-model")
        XCTAssertTrue(model.hasMoreMessages)

        let page = try await begin { await self.model.loadMoreMessages() }
        XCTAssertEqual(page.request.request.url?.lastPathComponent, "new")
        XCTAssertTrue(query(page.request).contains(URLQueryItem(name: "before_seq", value: "10")))
        page.request.respond(body: #"{"id":"new","messages":[],"has_more":false}"#)
        await fulfillment(of: [page.finished], timeout: 2)
        XCTAssertFalse(model.hasMoreMessages)
    }

    func testEmptyHistoryClearsOldMessagesPagingAndContextOnSuccess() async throws {
        try await loadOldConversation()
        let load = try await begin { await self.model.loadConversation("empty") }
        load.request.respond(body: #"{"id":"empty"}"#)
        await fulfillment(of: [load.finished], timeout: 2)

        XCTAssertEqual(model.conversationId, "empty")
        XCTAssertEqual(storage.get(config.conversationIdKey), "empty")
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertFalse(model.hasMoreMessages)
        XCTAssertNil(model.contextTokens)
        XCTAssertNil(model.contextWindow)
        XCTAssertNil(model.contextModelId)
        XCTAssertFalse(model.extendedThinking)
        XCTAssertEqual(model.runState, .idle)
        XCTAssertNil(model.error)
    }

    func testSuccessfulLegacyHistoryResetsPreviousKeysetCursorAndOffset() async throws {
        try await loadOldConversation()
        let load = try await begin { await self.model.loadConversation("legacy") }
        load.request.respond(body: #"{"id":"legacy","messages":[{"role":"user","content":"Question"},{"role":"assistant","content":"Answer"}],"hasMore":true}"#)
        await fulfillment(of: [load.finished], timeout: 2)
        let page = try await begin { await self.model.loadMoreMessages() }
        XCTAssertFalse(query(page.request).contains { $0.name == "before_seq" })
        XCTAssertTrue(query(page.request).contains(URLQueryItem(name: "offset", value: "2")))
        page.request.respond(body: #"{"id":"legacy","messages":[],"hasMore":false}"#)
        await fulfillment(of: [page.finished], timeout: 2)
    }

    func testFailedNotFoundMalformedAndOfflineLoadsPreserveOldConversationAndCursor() async throws {
        for failure in [500, 404, 200, 0] {
            try await loadOldConversation()
            let oldIDs = model.messages.map(\.id)
            let oldDates = model.messages.map(\.timestamp)
            var applied = true
            let load = try await begin { applied = await self.model.loadConversation("unavailable") }
            if failure == 0 {
                load.request.fail(URLError(.notConnectedToInternet))
            } else {
                load.request.respond(status: failure, body: "Non-JSON server diagnostics must not be displayed")
            }
            await fulfillment(of: [load.finished], timeout: 2)

            XCTAssertFalse(applied)
            XCTAssertEqual(model.conversationId, "old")
            XCTAssertEqual(storage.get(config.conversationIdKey), "old")
            XCTAssertEqual(model.messages.map(\.id), oldIDs)
            XCTAssertEqual(model.messages.map(\.timestamp), oldDates)
            XCTAssertEqual(model.messages.map(\.content), ["Old answer"])
            XCTAssertEqual(model.error, failure == 404 ? "Conversation not found." : "Conversation history could not be loaded.")
            XCTAssertFalse(model.isLoading)
            XCTAssertEqual(model.runState, .succeeded)
            XCTAssertTrue(model.extendedThinking)
            XCTAssertTrue(model.subAgentActivity.isActive)
            XCTAssertEqual(model.contextTokens, 123)
            XCTAssertEqual(model.contextWindow, 4096)
            XCTAssertEqual(model.contextModelId, "old-model")
            XCTAssertTrue(model.hasMoreMessages)

            let page = try await begin { await self.model.loadMoreMessages() }
            XCTAssertEqual(page.request.request.url?.lastPathComponent, "old")
            XCTAssertTrue(query(page.request).contains(URLQueryItem(name: "before_seq", value: "51")))
            page.request.respond(body: #"{"id":"old","messages":[],"has_more":false}"#)
            await fulfillment(of: [page.finished], timeout: 2)
        }
    }

    func testLatestRequestWinsEvenWhenOlderResponseOrFailureArrivesLast() async throws {
        for olderStatus in [200, 404, 500] {
            for latestStatus in [200, 404] {
                try await loadOldConversation()
                let older = try await begin { await self.model.loadConversation("older") }
                let latest = try await begin { await self.model.loadConversation("latest") }
                latest.request.respond(status: latestStatus, body: #"{"id":"latest","messages":[{"id":"latest","role":"assistant","content":"Latest answer"}]}"#)
                await fulfillment(of: [latest.finished], timeout: 2)
                older.request.respond(status: olderStatus, body: #"{"id":"older","messages":[{"role":"assistant","content":"Stale answer"}]}"#)
                await fulfillment(of: [older.finished], timeout: 2)

                XCTAssertEqual(model.conversationId, latestStatus == 200 ? "latest" : "old")
                XCTAssertEqual(storage.get(config.conversationIdKey), model.conversationId)
                XCTAssertEqual(model.messages.map(\.content), latestStatus == 200 ? ["Latest answer"] : ["Old answer"])
                XCTAssertEqual(model.error, latestStatus == 200 ? nil : "Conversation not found.")
                XCTAssertFalse(model.isLoading)
            }
        }
    }

    func testOlderCompletionCannotClearLoadingForNewerRequestOfSameConversation() async throws {
        try await loadOldConversation()
        let older = try await begin { await self.model.loadConversation("new") }
        let latest = try await begin { await self.model.loadConversation("new") }
        older.request.respond(status: 404)
        await fulfillment(of: [older.finished], timeout: 2)
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.conversationId, "old")
        latest.request.respond(body: #"{"id":"new","messages":[]}"#)
        await fulfillment(of: [latest.finished], timeout: 2)
        XCTAssertEqual(model.conversationId, "new")
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
    }

    func testClearLogoutReplacementAndBackgroundInvalidatePendingHistoryCallbacks() async throws {
        for action in ["clear", "logout", "replace", "background", "auth"] {
            for status in [200, 404, 500] {
                makeModel()
                try await loadOldConversation()
                let load = try await begin { await self.model.loadConversation("stale") }
                switch action {
                case "clear": model.clearMessages()
                case "logout": model.clearAllLocalData()
                case "replace": model.invalidateForReplacement()
                case "background": model.pauseForBackground()
                default: api.clearSession()
                }
                let expectedID = model.conversationId
                let expectedMessages = model.messages.map(\.id)
                let expectedError = model.error
                load.request.respond(status: status, body: #"{"id":"stale","messages":[{"role":"assistant","content":"Must not reappear"}]}"#)
                await fulfillment(of: [load.finished], timeout: 2)
                XCTAssertEqual(model.conversationId, expectedID)
                XCTAssertEqual(storage.get(config.conversationIdKey), expectedID)
                XCTAssertEqual(model.messages.map(\.id), expectedMessages)
                XCTAssertEqual(model.error, expectedError)
                XCTAssertFalse(model.isLoading)
            }
        }
    }

    func testAbortedReloadOfCurrentConversationReturnsFalseDespiteMatchingIDAndNoError() async throws {
        for action in ["background", "cancel"] {
            makeModel()
            try await loadOldConversation()
            var applied = true
            let load = try await begin { applied = await self.model.loadConversation("old") }
            if action == "background" { model.pauseForBackground() }
            else { tasks.last?.cancel() }
            load.request.respond(body: #"{"id":"old","messages":[]}"#)
            await fulfillment(of: [load.finished], timeout: 2)
            XCTAssertFalse(applied, "Host must not clear the draft after an aborted same-ID reload")
            XCTAssertEqual(model.conversationId, "old")
            XCTAssertNil(model.error)
            XCTAssertEqual(model.messages.map(\.content), ["Old answer"])
        }
    }

    func testSuccessfulSelectionDoesNotTriggerAnotherLaunchRestore() async throws {
        let load = try await begin { await self.model.loadConversation("selected") }
        load.request.respond(body: #"{"id":"selected","messages":[]}"#)
        await fulfillment(of: [load.finished], timeout: 2)
        expectNoRequests()
        await model.restoreConversationIfNeeded()
        XCTAssertEqual(model.conversationId, "selected")
    }

    func testFailedLaunchRestoreKeepsSavedIDAndCanBeRetriedExplicitly() async throws {
        storage.set(config.conversationIdKey, value: "saved")
        makeModel()
        let restore = try await begin { await self.model.restoreConversationIfNeeded() }
        restore.request.respond(status: 404)
        await fulfillment(of: [restore.finished], timeout: 2)
        XCTAssertEqual(model.conversationId, "saved")
        XCTAssertEqual(storage.get(config.conversationIdKey), "saved")
        XCTAssertEqual(model.error, "Conversation not found.")
        expectNoRequests()
        await model.restoreConversationIfNeeded()

        let retry = try await begin { await self.model.loadConversation("saved") }
        retry.request.respond(body: #"{"id":"saved","messages":[]}"#)
        await fulfillment(of: [retry.finished], timeout: 2)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.conversationId, "saved")
    }

    func testAnonymousRestoreCanAcquireItsInitialScopeWithoutDroppingHistory() async throws {
        config.authStrategy = .anonymous
        config.authToken = nil
        storage.set(config.conversationIdKey, value: "saved")
        makeModel()
        let restore = try await begin { await self.model.restoreConversationIfNeeded() }
        let historyRequested = expectation(description: "History follows anonymous session creation")
        var history: ControlledHistoryURLProtocol?
        ControlledHistoryURLProtocol.onRequest = { request in
            Task { @MainActor in
                history = request
                historyRequested.fulfill()
            }
        }
        restore.request.respond(body: #"{"token":"synthetic-anonymous-history-owner"}"#)
        await fulfillment(of: [historyRequested], timeout: 2)
        try XCTUnwrap(history).respond(body: #"{"id":"saved","messages":[{"role":"assistant","content":"Restored anonymously"}]}"#)
        await fulfillment(of: [restore.finished], timeout: 2)
        XCTAssertEqual(model.messages.map(\.content), ["Restored anonymously"])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
    }

    func testAuthInvalidationRejectsCallbacksEvenWhenBothRecoveryScopesAreNil() async throws {
        config.authStrategy = AuthStrategy.none
        config.authToken = nil
        makeModel()
        try await loadOldConversation()
        let load = try await begin { await self.model.loadConversation("stale") }
        XCTAssertNil(api.recoveryScope(agentKey: config.agentKey))
        api.clearSession()
        load.request.respond(body: #"{"id":"stale","messages":[]}"#)
        await fulfillment(of: [load.finished], timeout: 2)
        XCTAssertEqual(model.conversationId, "old")
        XCTAssertEqual(storage.get(config.conversationIdKey), "old")
        XCTAssertEqual(model.messages.map(\.content), ["Old answer"])
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
    }

    func testSavedConversationRestoresOnceAndHistoryNeverSpeaksOrFiresLifecycleHooks() async throws {
        var starts = 0
        var firstReplies = 0
        config.onConversationStart = { _ in starts += 1 }
        config.onFirstAssistantMessage = { _ in firstReplies += 1 }
        storage.set(config.conversationIdKey, value: "saved")
        makeModel()
        let spoke = expectation(description: "History must never request TTS")
        spoke.isInverted = true
        let voice = VoiceController(provider: HistoryTTSProbe(onSpeak: { spoke.fulfill() }))
        voice.setEnabled(true)
        voice.autoSpeakReplies = true
        model.voiceController = voice
        let load = try await begin { await self.model.restoreConversationIfNeeded() }
        XCTAssertEqual(load.request.request.url?.lastPathComponent, "saved")
        load.request.respond(body: #"{"id":"saved","messages":[{"role":"assistant","content":"A restored answer that must remain silent."}]}"#)
        await fulfillment(of: [load.finished], timeout: 2)
        expectNoRequests()
        await model.restoreConversationIfNeeded()
        await fulfillment(of: [spoke], timeout: 0.05)
        XCTAssertEqual(model.messages.map(\.content), ["A restored answer that must remain silent."])
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(firstReplies, 0)
        XCTAssertFalse(voice.isSpeaking)
        XCTAssertNotNil(model.appendAssistantMessage("Another silent turn"))
        XCTAssertEqual(firstReplies, 0, "Restored assistant history must latch the first-reply hook")

        let empty = try await begin { await self.model.loadConversation("empty") }
        empty.request.respond(body: #"{"id":"empty","messages":[]}"#)
        await fulfillment(of: [empty.finished], timeout: 2)
        XCTAssertNotNil(model.appendAssistantMessage("First reply in the empty conversation"))
        XCTAssertEqual(firstReplies, 1, "A different conversation must get its own first-reply latch")
    }

    func testSwitchCannotInterruptSendBeforePendingRecordExists() async throws {
        try await loadOldConversation()
        model.runState = .sending
        model.isLoading = true
        expectNoRequests()
        await model.loadConversation("other")
        XCTAssertFalse(model.hasPendingRun)
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.runState, .sending)
        XCTAssertEqual(model.conversationId, "old")
        XCTAssertEqual(storage.get(config.conversationIdKey), "old")
        XCTAssertEqual(model.messages.map(\.content), ["Old answer"])
    }

    func testPendingReplyBlocksSwitchButSameConversationStillReconciles() async throws {
        storage.set(config.conversationIdKey, value: "old")
        let store = PendingRunStore(storage: storage)
        let pending = PendingRun(scope: try XCTUnwrap(api.recoveryScope(agentKey: config.agentKey)),
            ownerScope: api.recoveryOwnerScope, idempotencyKey: "history-pending-send", body: Data("{}".utf8),
            createdAt: Date(), runId: "run", conversationId: "old", waiting: true,
            transcript: [PendingMessage(from: Message(id: "question", role: .user, content: "Pending question"))],
            messagesOffset: 1, hasMore: false)
        try store.save(pending)
        makeModel()
        expectNoRequests()
        await model.loadConversation("other")
        XCTAssertTrue(model.hasPendingRun)
        XCTAssertEqual(model.conversationId, "old")
        XCTAssertEqual(storage.get(config.conversationIdKey), "old")
        XCTAssertEqual(model.messages.map(\.content), ["Pending question"])
        XCTAssertEqual(store.load(scope: pending.scope)?.idempotencyKey, pending.idempotencyKey)

        let recovery = try await begin { await self.model.loadConversation("old") }
        XCTAssertEqual(recovery.request.request.url?.lastPathComponent, "run")
        recovery.request.respond(body: #"{"id":"run","conversation_id":"old","status":"succeeded","output":{"final_messages":[{"role":"assistant","content":"Recovered answer"}]}}"#)
        await fulfillment(of: [recovery.finished], timeout: 2)
        XCTAssertFalse(model.hasPendingRun)
        XCTAssertEqual(model.messages.map(\.content), ["Pending question", "Recovered answer"])
        XCTAssertEqual(model.runState, .succeeded)
        XCTAssertNil(model.error)
        XCTAssertNil(store.load(scope: pending.scope))
    }

    private func makeModel() {
        model?.invalidateForReplacement()
        api?.session.invalidateAndCancel()
        api = APIClient(config: config, storage: storage)
        model = ChatViewModel(config: config, apiClient: api, storage: storage)
    }

    private func loadOldConversation() async throws {
        let load = try await begin { await self.model.loadConversation("old") }
        load.request.respond(body: #"{"id":"old","messages":[{"id":"old-answer","seq":51,"role":"assistant","content":"Old answer"}],"has_more":true,"next_before_seq":51}"#)
        await fulfillment(of: [load.finished], timeout: 2)
        model.extendedThinking = true
        model.runState = .succeeded
        model.subAgentActivity.push(.init(agentName: "Old helper"))
        model.applyContextUsage(["total_tokens": 123, "context_window": 4096, "model_id": "old-model"])
        model.error = "An earlier error"
    }

    private func begin(_ operation: @escaping @MainActor () async -> Void) async throws
        -> (request: ControlledHistoryURLProtocol, finished: XCTestExpectation) {
        let received = expectation(description: "Stub receives request")
        let finished = expectation(description: "Load completes")
        var captured: ControlledHistoryURLProtocol?
        ControlledHistoryURLProtocol.onRequest = { request in
            Task { @MainActor in
                captured = request
                received.fulfill()
            }
        }
        tasks.append(Task { await operation(); finished.fulfill() })
        await fulfillment(of: [received], timeout: 2)
        return (try XCTUnwrap(captured), finished)
    }

    private func query(_ request: ControlledHistoryURLProtocol) -> [URLQueryItem] {
        URLComponents(url: request.request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    private func expectNoRequests() {
        ControlledHistoryURLProtocol.onRequest = { request in
            XCTFail("Unexpected request while restoring or guarding conversation state")
            request.respond(status: 400)
        }
    }
}

/// Holds each request until the test explicitly completes it. No sleeps,
/// blocked URLSession queues, or external HTTP are needed to order responses.
private final class ControlledHistoryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((ControlledHistoryURLProtocol) -> Void)?
    static var onRequest: ((ControlledHistoryURLProtocol) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); defer { lock.unlock() }; handler = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.onRequest else { fail(URLError(.unsupportedURL)); return }
        handler(self)
    }
    override func stopLoading() {}

    func respond(status: Int = 200, body: String = "") {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}

private final class HistoryTTSProbe: TTSProvider {
    let name = "history-test"
    private let onSpeak: () -> Void
    init(onSpeak: @escaping () -> Void) { self.onSpeak = onSpeak }
    func speak(_ text: String, options: TTSSpeakOptions) async throws { onSpeak() }
    func cancel() {}
    func listVoices() async throws -> [VoiceDescriptor] { [] }
}