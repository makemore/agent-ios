import XCTest
@testable import AgentClient

final class ContentBlockTests2: XCTestCase {

    func testParseStatusBlock() {
        let json: [[String: Any]] = [
            ["type": "status", "state": "loading", "title": "Processing", "body": "Please wait", "progress": 0.5]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        if case .status(let status) = blocks[0] {
            XCTAssertEqual(status.state, "loading")
            XCTAssertEqual(status.title, "Processing")
            XCTAssertEqual(status.body, "Please wait")
            XCTAssertEqual(status.progress, 0.5)
        } else {
            XCTFail("Expected status block")
        }
    }

    func testParseLocationBlock() {
        let json: [[String: Any]] = [
            ["type": "location", "latitude": 51.5074, "longitude": -0.1278, "label": "London", "zoom": 12]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        if case .location(let loc) = blocks[0] {
            XCTAssertEqual(loc.latitude, 51.5074, accuracy: 0.0001)
            XCTAssertEqual(loc.longitude, -0.1278, accuracy: 0.0001)
            XCTAssertEqual(loc.label, "London")
            XCTAssertEqual(loc.zoom, 12)
        } else {
            XCTFail("Expected location block")
        }
    }

    func testParseImageBlock() {
        let json: [[String: Any]] = [
            ["type": "image", "url": "https://example.com/pic.png", "alt": "A picture", "caption": "Nice view"]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        if case .image(let img) = blocks[0] {
            XCTAssertEqual(img.url, "https://example.com/pic.png")
            XCTAssertEqual(img.alt, "A picture")
            XCTAssertEqual(img.caption, "Nice view")
        } else {
            XCTFail("Expected image block")
        }
    }

    func testParseCollapsibleBlock() {
        let json: [[String: Any]] = [
            ["type": "collapsible", "title": "Details", "body": "More info here", "defaultOpen": true]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        if case .collapsible(let c) = blocks[0] {
            XCTAssertEqual(c.title, "Details")
            XCTAssertEqual(c.body, "More info here")
            XCTAssertEqual(c.defaultOpen, true)
        } else {
            XCTFail("Expected collapsible block")
        }
    }

    func testParseFileBlock() {
        let json: [[String: Any]] = [
            ["type": "file", "filename": "report.pdf", "url": "https://example.com/report.pdf", "mimeType": "application/pdf", "size": 1024]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        if case .file(let file) = blocks[0] {
            XCTAssertEqual(file.filename, "report.pdf")
            XCTAssertEqual(file.url, "https://example.com/report.pdf")
            XCTAssertEqual(file.mimeType, "application/pdf")
            XCTAssertEqual(file.size, 1024)
        } else {
            XCTFail("Expected file block")
        }
    }

    func testParseActionButtonsBlock() {
        let json: [[String: Any]] = [
            [
                "type": "actionButtons",
                "buttons": [
                    ["type": "message", "label": "Yes", "message": "Confirmed"],
                    ["type": "link", "label": "Docs", "url": "https://docs.example.com"]
                ]
            ]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        if case .actionButtons(let ab) = blocks[0] {
            XCTAssertEqual(ab.buttons.count, 2)
            XCTAssertEqual(ab.buttons[0].type, "message")
            XCTAssertEqual(ab.buttons[0].message, "Confirmed")
            XCTAssertEqual(ab.buttons[1].type, "link")
            XCTAssertEqual(ab.buttons[1].url, "https://docs.example.com")
        } else {
            XCTFail("Expected actionButtons block")
        }
    }

    func testParseUnknownBlockTypeSkipped() {
        let json: [[String: Any]] = [
            ["type": "futureWidget", "data": "something"],
            ["type": "card", "title": "Known"]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .unknown)
        if case .card(let card) = blocks[1] {
            XCTAssertEqual(card.title, "Known")
        } else {
            XCTFail("Expected card block")
        }
    }

    func testParseMultipleMixedBlocks() {
        let json: [[String: Any]] = [
            ["type": "callout", "style": "info", "body": "Hello"],
            ["type": "divider"],
            ["type": "table", "headers": ["A"], "rows": [["1"]]],
            ["type": "code", "code": "x = 1"]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 4)
        if case .callout = blocks[0] {} else { XCTFail("Expected callout") }
        XCTAssertEqual(blocks[1], .divider)
        if case .table = blocks[2] {} else { XCTFail("Expected table") }
        if case .code = blocks[3] {} else { XCTFail("Expected code") }
    }

    func testParseEmptyArrayReturnsEmpty() {
        let blocks = ContentBlock.parse(from: [])
        XCTAssertTrue(blocks.isEmpty)
    }

    func testContentBlocksMessageType() {
        let msg = Message(
            role: .assistant,
            content: "",
            type: .contentBlocks,
            metadata: MessageMetadata(contentBlocks: [.divider])
        )

        XCTAssertEqual(msg.type, .contentBlocks)
        XCTAssertEqual(msg.metadata?.contentBlocks?.count, 1)
        XCTAssertEqual(msg.metadata?.contentBlocks?[0], .divider)
    }

    func testCardBlockRoundTripCodable() throws {
        let original = ContentBlock.card(CardBlock(
            type: "card", title: "Test", subtitle: "Sub", badge: "New"
        ))
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([ContentBlock].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0], original)
    }
}
