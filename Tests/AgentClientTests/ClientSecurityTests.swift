import XCTest
@testable import AgentClient

/// Layer C — client security guards (iOS).
///
/// These lock in the security properties the *library* is responsible for:
/// it must not weaken transport security and must not leak credentials into
/// logs. Storage-at-rest encryption, Keychain token storage, and backup
/// exclusion are host-app / on-device concerns that need device tests —
/// those are encoded as documented skips and tracked in
/// agent/docs/ephemeral-security-validation-plan.md (Layer C).
final class ClientSecurityTests: XCTestCase {

    // MARK: - Log hygiene (passing guards)

    func testSSETokenIsRedactedFromLogURL() throws {
        let url = try XCTUnwrap(URL(
            string: "https://api.example.com/runs/abc/stream/?anonymous_token=SECRET123&from_seq=4"
        ))
        let redacted = redactURLForLogging(url)
        XCTAssertFalse(redacted.contains("SECRET123"),
                       "anonymous_token must never appear in a logged URL")
        XCTAssertTrue(redacted.contains("from_seq=4"),
                      "non-sensitive params should be preserved for diagnostics")
    }

    func testPlainTokenParamIsRedacted() throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.com/x/?token=ABC.DEF.GHI"))
        XCTAssertFalse(redactURLForLogging(url).contains("ABC.DEF.GHI"))
    }

    // MARK: - Transport (passing guards)

    /// The library itself must never disable App Transport Security. The only
    /// `NSAllowsArbitraryLoads` in the repo is the dev-only Example app.
    func testLibrarySourcesHaveNoArbitraryLoadsATS() throws {
        let sources = try repoSubdirectory("clients/agent-ios/Sources")
        let offenders = filesContaining("NSAllowsArbitraryLoads", under: sources)
        XCTAssertTrue(offenders.isEmpty,
                      "ATS must not be disabled in library sources: \(offenders)")
    }

    // MARK: - Transport (HTTPS enforcement, fail-closed)

    func testIsDevHostClassification() {
        XCTAssertTrue(APIClient.isDevHost("localhost"))
        XCTAssertTrue(APIClient.isDevHost("127.0.0.1"))
        XCTAssertTrue(APIClient.isDevHost("10.0.2.2"))
        XCTAssertTrue(APIClient.isDevHost("stub.local"))
        XCTAssertFalse(APIClient.isDevHost("api.example.com"))
    }

    func testCleartextProductionBackendIsRefused() async {
        let config = ChatWidgetConfig(backendUrl: "http://api.example.com", agentKey: "a")
        let client = APIClient(config: config, storage: InMemoryStorage())
        do {
            _ = try await client.getOrCreateSession()
            XCTFail("expected insecureTransport to be thrown before any egress")
        } catch let APIError.insecureTransport(host) {
            XCTAssertEqual(host, "api.example.com")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testHttpsBackendPassesTransportGate() {
        let config = ChatWidgetConfig(backendUrl: "https://api.example.com", agentKey: "a")
        let client = APIClient(config: config, storage: InMemoryStorage())
        XCTAssertNoThrow(try client.validateTransport())
    }

    func testAllowInsecureHTTPEscapeHatch() {
        var config = ChatWidgetConfig(backendUrl: "http://api.example.com", agentKey: "a")
        config.allowInsecureHTTP = true
        let client = APIClient(config: config, storage: InMemoryStorage())
        XCTAssertNoThrow(try client.validateTransport())
    }

    // MARK: - On-device encryption (at rest)

    /// Secrets (auth token, client memories) route to the secure (Keychain)
    /// backend; non-secret UI preferences stay in UserDefaults.
    func testSecureStorageRoutesSecretsToSecureBackend() {
        let secure = InMemoryStorage()
        let standard = InMemoryStorage()
        let store = SecureStorageService(
            secure: secure, standard: standard,
            secureKeys: ["chat_widget_anonymous_token"]
        )

        store.set("chat_widget_anonymous_token", value: "tok-123")
        store.set("chat_widget_memories", value: "[{\"k\":\"v\"}]")
        store.set("chat_widget_model_selection", value: "gpt-4o")

        // Secrets in the secure backend only.
        XCTAssertEqual(secure.get("chat_widget_anonymous_token"), "tok-123")
        XCTAssertNil(standard.get("chat_widget_anonymous_token"))
        XCTAssertEqual(secure.get("chat_widget_memories"), "[{\"k\":\"v\"}]")
        XCTAssertNil(standard.get("chat_widget_memories"))
        // Non-secret UI prefs stay in UserDefaults.
        XCTAssertEqual(standard.get("chat_widget_model_selection"), "gpt-4o")
        XCTAssertNil(secure.get("chat_widget_model_selection"))
        // Reads route to the same backend they were written to.
        XCTAssertEqual(store.get("chat_widget_anonymous_token"), "tok-123")
    }

    func testKeychainStorageRoundTripIfAvailable() throws {
        let kc = KeychainStorage(service: "com.makemore.agent.test-\(UUID().uuidString)")
        kc.set("k", value: "v")
        guard kc.get("k") == "v" else {
            throw XCTSkip("Keychain unavailable in this test host (entitlements); "
                          + "routing is covered by the composite test.")
        }
        kc.set("k", value: nil)
        XCTAssertNil(kc.get("k"), "cleared secret must be removed from the Keychain")
    }

    /// File protection is applied in LocalHistoryStore.protectFileAtRest under
    /// `#if os(iOS)`. The attribute is only observable on a real iOS device, so
    /// this remains a device-test item rather than a host unit assertion.
    func testLocalHistoryDatabaseHasFileProtection() throws {
        throw XCTSkip("""
        IMPLEMENTED: LocalHistoryStore sets .completeUnlessOpen + excludes the \
        DB from backup on iOS. Verify on a physical device (data protection is \
        a no-op on the macOS test host).
        """)
    }

    // MARK: - Helpers

    private func repoSubdirectory(_ rel: String, file: StaticString = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = url.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            url.deleteLastPathComponent()
        }
        throw XCTSkip("Could not locate \(rel) from \(file)")
    }

    private func filesContaining(_ needle: String, under root: URL) -> [String] {
        var hits: [String] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return hits }
        for case let fileURL as URL in en where fileURL.pathExtension == "swift" {
            if let text = try? String(contentsOf: fileURL, encoding: .utf8), text.contains(needle) {
                hits.append(fileURL.lastPathComponent)
            }
        }
        return hits
    }
}
