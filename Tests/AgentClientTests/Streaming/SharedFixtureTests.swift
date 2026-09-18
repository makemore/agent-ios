import XCTest

final class SharedFixtureTests: XCTestCase {
    func testMissingFixtureAtFilesystemRootTerminates() {
        XCTAssertThrowsError(try SharedFixture.locate(
            "sse/missing-\(UUID().uuidString).json",
            from: URL(fileURLWithPath: "/", isDirectory: true)
        ))
    }

    func testCanonicalMetaRepoFixturesWinOverNearerLegacyCopiesAtAnyDepth() throws {
        try withFixtureTree { root in
            let client = root.appendingPathComponent("clients/agent-ios")
            let nested = Array(repeating: "nested", count: 12).joined(separator: "/")
            let start = client.appendingPathComponent("Tests/AgentClientTests/Streaming/\(nested)")
            try FileManager.default.createDirectory(at: start, withIntermediateDirectories: true)
            for relativePath in ["sse/probe.json", "ephemeral/contract.json"] {
                let canonical = try writeFixture("test-harness/fixtures/\(relativePath)", under: root)
                _ = try writeFixture("test-fixtures/\(relativePath)", under: client)
                _ = try writeFixture("clients/test-fixtures/\(relativePath)", under: root)
                XCTAssertEqual(try SharedFixture.locate(relativePath, from: start).path, canonical.path)
            }
        }
    }

    func testStandaloneAndLegacyClientsLayouts() throws {
        for layout in ["test-fixtures", "clients/test-fixtures"] {
            try withFixtureTree { root in
                let start = root.appendingPathComponent("agent-ios/Tests/AgentClientTests/Streaming")
                try FileManager.default.createDirectory(at: start, withIntermediateDirectories: true)
                // Unique names prevent fixtures above a custom temporary directory from interfering.
                for category in ["sse", "ephemeral"] {
                    let relativePath = "\(category)/probe-\(root.lastPathComponent).json"
                    let expected = try writeFixture("\(layout)/\(relativePath)", under: root)
                    XCTAssertEqual(try SharedFixture.locate(relativePath, from: start).path, expected.path)
                }
            }
        }
    }

    func testSearchesForRequestedFileRatherThanAnExistingDirectory() throws {
        try withFixtureTree { root in
            for category in ["sse", "ephemeral"] {
                _ = try writeFixture("test-harness/fixtures/\(category)/other.json", under: root)
                let relativePath = "\(category)/probe-\(root.lastPathComponent).json"
                let expected = try writeFixture("test-fixtures/\(relativePath)", under: root)
                XCTAssertEqual(try SharedFixture.locate(relativePath, from: root).path, expected.path)
            }
        }
    }

    func testRejectsDirectoriesAndReportsMissingFileAndSearchedPaths() throws {
        try withFixtureTree { root in
            let relativePath = "sse/missing-\(root.lastPathComponent).json"
            let candidate = root.appendingPathComponent("test-harness/fixtures/\(relativePath)")
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            XCTAssertThrowsError(try SharedFixture.locate(relativePath, from: root)) { error in
                let message = error.localizedDescription
                XCTAssertTrue(message.contains(relativePath))
                XCTAssertTrue(message.contains("from \(root.path)"))
                XCTAssertTrue(message.contains(candidate.path))
                XCTAssertTrue(message.contains("Check out test-harness/fixtures"))
                XCTAssertTrue(message.contains(root.appendingPathComponent("test-fixtures/\(relativePath)").path))
                XCTAssertTrue(message.contains(root.appendingPathComponent("clients/test-fixtures/\(relativePath)").path))
            }
        }
    }

    func testCheckedInSSEFixturesAndEphemeralContractLoad() throws {
        let fixture = try SSEFixture.load("simple_streaming")
        XCTAssertEqual(fixture.name, "simple_streaming")
        XCTAssertFalse(fixture.events.isEmpty)
        let contract = try EphemeralContract.load()
        XCTAssertFalse(contract.scenarios.isEmpty)
        for scenario in contract.scenarios {
            XCTAssertFalse(try SSEFixture.load(scenario.fixture).events.isEmpty)
        }
    }

    private func withFixtureTree(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-ios-fixtures-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func writeFixture(_ relativePath: String, under root: URL) throws -> URL {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: file)
        return file
    }
}