import XCTest
@testable import AgentClient

final class ContentBlockTests: XCTestCase {

    func testParseCardBlock() {
        let json: [[String: Any]] = [
            [
                "type": "card",
                "title": "Beach House",
                "subtitle": "$450/night",
                "badge": "Featured",
                "image": "https://example.com/beach.jpg"
            ]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        if case .card(let card) = blocks[0] {
            XCTAssertEqual(card.title, "Beach House")
            XCTAssertEqual(card.subtitle, "$450/night")
            XCTAssertEqual(card.badge, "Featured")
            XCTAssertEqual(card.image, "https://example.com/beach.jpg")
        } else {
            XCTFail("Expected card block")
        }
    }

    func testParseCardWithMetadataAndActions() {
        let json: [[String: Any]] = [
            [
                "type": "card",
                "title": "Product",
                "metadata": [
                    ["label": "Price", "value": "$99"],
                    ["label": "Stock", "value": "12"]
                ],
                "actions": [
                    ["type": "link", "label": "View", "url": "https://example.com", "style": "primary"],
                    ["type": "callback", "label": "Buy", "callbackId": "buy-123", "style": "secondary"]
                ]
            ]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        if case .card(let card) = blocks[0] {
            XCTAssertEqual(card.metadata?.count, 2)
            XCTAssertEqual(card.metadata?[0].label, "Price")
            XCTAssertEqual(card.metadata?[0].value, "$99")
            XCTAssertEqual(card.actions?.count, 2)
            XCTAssertEqual(card.actions?[0].type, "link")
            XCTAssertEqual(card.actions?[0].url, "https://example.com")
            XCTAssertEqual(card.actions?[1].type, "callback")
            XCTAssertEqual(card.actions?[1].callbackId, "buy-123")
        } else {
            XCTFail("Expected card block")
        }
    }

    func testParseCardListBlock() {
        let json: [[String: Any]] = [
            [
                "type": "cardList",
                "layout": "horizontal",
                "items": [
                    ["type": "card", "title": "Item 1"],
                    ["type": "card", "title": "Item 2"]
                ]
            ]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        if case .cardList(let list) = blocks[0] {
            XCTAssertEqual(list.layout, "horizontal")
            XCTAssertEqual(list.items.count, 2)
            XCTAssertEqual(list.items[0].title, "Item 1")
            XCTAssertEqual(list.items[1].title, "Item 2")
        } else {
            XCTFail("Expected cardList block")
        }
    }

    func testParseCalloutBlock() {
        let json: [[String: Any]] = [
            ["type": "callout", "style": "warning", "title": "Watch out", "body": "Be careful here"]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        if case .callout(let callout) = blocks[0] {
            XCTAssertEqual(callout.style, "warning")
            XCTAssertEqual(callout.title, "Watch out")
            XCTAssertEqual(callout.body, "Be careful here")
        } else {
            XCTFail("Expected callout block")
        }
    }

    func testParseTableBlock() {
        let json: [[String: Any]] = [
            [
                "type": "table",
                "headers": ["Name", "Price"],
                "rows": [["Widget", "$10"], ["Gadget", "$20"]]
            ]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        if case .table(let table) = blocks[0] {
            XCTAssertEqual(table.headers, ["Name", "Price"])
            XCTAssertEqual(table.rows?.count, 2)
            XCTAssertEqual(table.rows?[0], ["Widget", "$10"])
        } else {
            XCTFail("Expected table block")
        }
    }

    func testParseCodeBlock() {
        let json: [[String: Any]] = [
            ["type": "code", "language": "python", "code": "print('hello')", "filename": "main.py", "copyable": true]
        ]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        if case .code(let code) = blocks[0] {
            XCTAssertEqual(code.language, "python")
            XCTAssertEqual(code.code, "print('hello')")
            XCTAssertEqual(code.filename, "main.py")
            XCTAssertEqual(code.copyable, true)
        } else {
            XCTFail("Expected code block")
        }
    }

    func testParseDividerBlock() {
        let json: [[String: Any]] = [["type": "divider"]]
        let blocks = ContentBlock.parse(from: json)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0], .divider)
    }
}
