import XCTest
@testable import AgentFrontend
@testable import AgentClient

final class AgentFrontendTests: XCTestCase {

    // MARK: - AgentFrontend convenience API (requires both modules)

    func testConfigurationMake() {
        let config = ChatWidgetConfig.make(
            backendUrl: "https://api.example.com",
            agentKey: "test-agent",
            title: "Test Chat"
        )

        XCTAssertEqual(config.backendUrl, "https://api.example.com")
        XCTAssertEqual(config.agentKey, "test-agent")
        XCTAssertEqual(config.title, "Test Chat")
    }

    // MARK: - VideoBlockView full-screen callback

    func testVideoBlockViewFullScreenCallbackDefaultsNil() {
        let block = VideoBlock(
            type: "video",
            url: "https://example.com/a.mp4",
            title: nil, caption: nil, thumbnailUrl: nil, autoplay: nil, mimeType: nil
        )
        let view = VideoBlockView(block: block)
        XCTAssertNil(view.onFullScreenChange)
    }

    func testVideoBlockViewForwardsFullScreenCallback() {
        var received: [Bool] = []
        let block = VideoBlock(
            type: "video",
            url: "https://example.com/a.mp4",
            title: "T", caption: nil, thumbnailUrl: nil, autoplay: nil, mimeType: nil
        )
        let view = VideoBlockView(block: block, onFullScreenChange: { received.append($0) })
        view.onFullScreenChange?(true)
        view.onFullScreenChange?(false)
        XCTAssertEqual(received, [true, false])
    }

    // MARK: - ChatWidgetConfig video full-screen wiring

    func testChatWidgetConfigVideoFullScreenDefaultsNil() {
        let config = ChatWidgetConfig()
        XCTAssertNil(config.onVideoFullScreenChange)
    }

    func testChatWidgetConfigVideoFullScreenIsAssignable() {
        var received: [Bool] = []
        var config = ChatWidgetConfig()
        config.onVideoFullScreenChange = { received.append($0) }
        config.onVideoFullScreenChange?(true)
        config.onVideoFullScreenChange?(false)
        XCTAssertEqual(received, [true, false])
    }

    // MARK: - Markdown block parsing

    func testNumberedListWithBlankLinesStaysOneList() {
        // The agent emits loose lists (blank line between items) constantly.
        // Each item used to become its own list block, so every item
        // rendered as "1." — the reported bug.
        let blocks = MarkdownBlockParser.parse("""
        1. Box breathing

        2. Grounding

        3. Cold water
        """)
        XCTAssertEqual(blocks, [
            .numberedList(items: ["Box breathing", "Grounding", "Cold water"], start: 1)
        ])
    }

    func testTightNumberedListStillParsesAsOneList() {
        let blocks = MarkdownBlockParser.parse("""
        1. First
        2. Second
        """)
        XCTAssertEqual(blocks, [.numberedList(items: ["First", "Second"], start: 1)])
    }

    func testNumberedListPreservesStartNumber() {
        // A list that opens at 3 keeps counting from 3 rather than renumbering.
        let blocks = MarkdownBlockParser.parse("""
        3. Third
        4. Fourth
        """)
        XCTAssertEqual(blocks, [.numberedList(items: ["Third", "Fourth"], start: 3)])
    }

    func testBulletListWithBlankLinesStaysOneList() {
        let blocks = MarkdownBlockParser.parse("""
        - One

        - Two
        """)
        XCTAssertEqual(blocks, [.bulletList(["One", "Two"])])
    }

    func testParagraphAfterListEndsTheList() {
        let blocks = MarkdownBlockParser.parse("""
        1. Box breathing

        Let me know how that lands.
        """)
        XCTAssertEqual(blocks, [
            .numberedList(items: ["Box breathing"], start: 1),
            .paragraph("Let me know how that lands.")
        ])
    }

    func testDecimalIsNotTreatedAsListItem() {
        // "3.5 seconds" has no space after the dot, so it stays prose.
        let blocks = MarkdownBlockParser.parse("Breathe out for 3.5 seconds in total.")
        XCTAssertEqual(blocks, [.paragraph("Breathe out for 3.5 seconds in total.")])
    }

    func testHeadingAndParagraphUnaffected() {
        let blocks = MarkdownBlockParser.parse("""
        ## Try this

        One steady breath.
        """)
        XCTAssertEqual(blocks, [
            .heading(text: "Try this", level: 2),
            .paragraph("One steady breath.")
        ])
    }

    func testCodeBlockUnaffected() {
        let blocks = MarkdownBlockParser.parse("""
        ```swift
        let x = 1
        ```
        """)
        XCTAssertEqual(blocks, [.codeBlock(code: "let x = 1", language: "swift")])
    }

}

