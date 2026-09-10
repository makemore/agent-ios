import XCTest
import AgentClient
@testable import AgentFrontend

final class SidebarHistoryTests: XCTestCase {
    @MainActor
    private final class SuspendedLoader {
        let started = XCTestExpectation(description: "History loader started")
        private var continuation: CheckedContinuation<[Conversation], Error>?

        func load() async throws -> [Conversation] {
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }

        func finish(_ result: Result<[Conversation], Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    @MainActor
    func testSuccessShowsLoadingBeforePublishingResults() async {
        let model = SidebarHistoryModel()
        XCTAssertEqual(model.phase, .idle)
        await model.load(recentsLimit: 30) {
            XCTAssertEqual(model.phase, .loading)
            XCTAssertTrue(model.conversations.isEmpty)
            return [Conversation(id: "one")]
        }
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.conversations.map(\.id), ["one"])
    }

    @MainActor
    func testEmptySuccessIsDifferentFromUnavailableHistory() async {
        let model = SidebarHistoryModel()
        await model.load(recentsLimit: 30) { [] }
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.conversations.isEmpty)

        await model.load(recentsLimit: 30, using: nil)
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertTrue(model.conversations.isEmpty)
    }

    @MainActor
    func testFailureCanRetryTheSameLoaderSuccessfully() async {
        let model = SidebarHistoryModel()
        var attempts = 0
        let loader: SidebarHistoryModel.Loader = {
            attempts += 1
            XCTAssertEqual(model.phase, .loading)
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return [Conversation(id: "retried")]
        }
        await model.load(recentsLimit: 30, using: loader)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.conversations.isEmpty)
        await model.load(recentsLimit: 30, using: loader)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.conversations.map(\.id), ["retried"])
    }

    @MainActor
    func testSortUsesUpdatedThenCreatedDateWithStableUndatedOrderBeforeLimiting() async {
        let model = SidebarHistoryModel()
        let conversations = [
            Conversation(id: "undated-b"),
            Conversation(id: "updated", createdAt: Date(timeIntervalSince1970: 80),
                         updatedAt: Date(timeIntervalSince1970: 20)),
            Conversation(id: "created", createdAt: Date(timeIntervalSince1970: 30)),
            Conversation(id: "undated-a"),
            Conversation(id: "newest", updatedAt: Date(timeIntervalSince1970: 40)),
        ]
        await model.load(recentsLimit: 30) { conversations }
        XCTAssertEqual(model.conversations.map(\.id),
                       ["newest", "created", "updated", "undated-a", "undated-b"])
        await model.load(recentsLimit: 2) { conversations }
        XCTAssertEqual(model.conversations.map(\.id), ["newest", "created"])
    }

    @MainActor
    func testLimitsAreSafelyClampedAndNonpositiveLimitsSkipLoading() async {
        let model = SidebarHistoryModel()
        for limit in [Int.min, -1, 0] {
            XCTAssertEqual(SidebarHistoryModel.clampedLimit(limit), 0)
            await model.load(recentsLimit: limit) {
                XCTFail("Disabled recents must not load history")
                return []
            }
            XCTAssertEqual(model.phase, .loaded)
            XCTAssertTrue(model.conversations.isEmpty)
        }
        XCTAssertEqual(SidebarHistoryModel.clampedLimit(30), 30)
        XCTAssertEqual(SidebarHistoryModel.clampedLimit(Int.max), 100)
        await model.load(recentsLimit: Int.max) {
            (0..<120).map {
                Conversation(id: String($0), updatedAt: Date(timeIntervalSince1970: Double($0)))
            }
        }
        XCTAssertEqual(model.conversations.count, 100)
        XCTAssertEqual(model.conversations.first?.id, "119")
        XCTAssertEqual(model.conversations.last?.id, "20")
    }

    @MainActor
    func testTitlesAreTrimmedAndBlankTitlesHaveAFallback() async {
        let blankTitles: [String?] = [nil, "", " \n\t ", "\u{00A0}"]
        for title in blankTitles {
            XCTAssertEqual(SidebarHistoryModel.displayTitle(for: Conversation(id: "one", title: title)),
                           "Untitled conversation")
        }
        XCTAssertEqual(SidebarHistoryModel.displayTitle(for: Conversation(id: "one", title: " \nTrip plans\t ")),
                       "Trip plans")
    }

    @MainActor
    func testCancelledTaskDiscardsALateSuccessWithoutShowingFailure() async {
        let model = SidebarHistoryModel()
        let loader = SuspendedLoader()
        let task = Task { await model.load(recentsLimit: 30, using: loader.load) }
        await fulfillment(of: [loader.started], timeout: 1)
        XCTAssertEqual(model.phase, .loading)
        task.cancel()
        loader.finish(.success([Conversation(id: "cancelled")]))
        await task.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.conversations.isEmpty)
        await model.load(recentsLimit: 30) { [Conversation(id: "reopened")] }
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.conversations.map(\.id), ["reopened"])
    }

    @MainActor
    func testCancellationErrorsAreNotFailures() async {
        let model = SidebarHistoryModel()
        let errors: [Error] = [CancellationError(), URLError(.cancelled)]
        for error in errors {
            await model.load(recentsLimit: 30) { throw error }
            XCTAssertEqual(model.phase, .idle)
            XCTAssertTrue(model.conversations.isEmpty)
        }
    }

    @MainActor
    func testOlderSuccessOrFailureCannotOverwriteANewerLoad() async {
        let results: [Result<[Conversation], Error>] = [
            .success([Conversation(id: "stale")]), .failure(URLError(.timedOut)),
        ]
        for result in results {
            let model = SidebarHistoryModel()
            let loader = SuspendedLoader()
            let oldTask = Task { await model.load(recentsLimit: 30, using: loader.load) }
            await fulfillment(of: [loader.started], timeout: 1)
            await model.load(recentsLimit: 30) { [Conversation(id: "current")] }
            loader.finish(result)
            await oldTask.value
            XCTAssertEqual(model.phase, .loaded)
            XCTAssertEqual(model.conversations.map(\.id), ["current"])
        }
    }

    @MainActor
    func testResetInvalidatesAnInFlightLoad() async {
        let model = SidebarHistoryModel()
        let loader = SuspendedLoader()
        let task = Task { await model.load(recentsLimit: 30, using: loader.load) }
        await fulfillment(of: [loader.started], timeout: 1)
        model.reset()
        XCTAssertEqual(model.phase, .idle)
        loader.finish(.success([Conversation(id: "dismissed")]))
        await task.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.conversations.isEmpty)
    }

    @MainActor
    func testPanelWidthIsCappedAndLeavesRoomForDismissal() async {
        XCTAssertEqual(ChatSidebarView.panelWidth(availableWidth: 1024), 360)
        XCTAssertEqual(ChatSidebarView.panelWidth(availableWidth: 390), 312)
        XCTAssertEqual(ChatSidebarView.panelWidth(availableWidth: 320), 276)
        let widths: [CGFloat] = [0, 44, 100, 200, 320, 390, 768, 1024]
        for width in widths {
            let panel = ChatSidebarView.panelWidth(availableWidth: width)
            XCTAssertGreaterThanOrEqual(panel, 0)
            XCTAssertLessThanOrEqual(panel, 360)
            XCTAssertLessThanOrEqual(panel, max(0, width - 44))
        }
    }
}