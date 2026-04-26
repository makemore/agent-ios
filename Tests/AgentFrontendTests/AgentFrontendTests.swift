import XCTest
@testable import AgentFrontend

final class AgentFrontendTests: XCTestCase {
    
    // MARK: - Configuration Tests
    
    func testDefaultConfiguration() {
        let config = ChatWidgetConfig()
        
        XCTAssertEqual(config.backendUrl, "http://localhost:8000")
        XCTAssertEqual(config.agentKey, "default-agent")
        XCTAssertEqual(config.title, "Chat Assistant")
        XCTAssertTrue(config.showTasksTab)
    }
    
    func testCustomConfiguration() {
        var config = ChatWidgetConfig(backendUrl: "https://api.example.com", agentKey: "my-agent")
        config.title = "My Chat"
        config.showTasksTab = false

        XCTAssertEqual(config.backendUrl, "https://api.example.com")
        XCTAssertEqual(config.agentKey, "my-agent")
        XCTAssertEqual(config.title, "My Chat")
        XCTAssertFalse(config.showTasksTab)
    }
    
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
    
    // MARK: - API Paths Tests
    
    func testDefaultAPIPaths() {
        let paths = APIPaths()
        
        XCTAssertEqual(paths.conversations, "/api/agent-runtime/conversations/")
        XCTAssertEqual(paths.runs, "/api/agent-runtime/runs/")
    }
    
    func testRunEventsUrl() {
        let paths = APIPaths()
        let url = paths.runEventsUrl(for: "abc123")
        
        XCTAssertEqual(url, "/api/agent-runtime/runs/abc123/stream/")
    }
    
    func testCancelRunUrl() {
        let paths = APIPaths()
        let url = paths.cancelRunUrl(for: "abc123")
        
        XCTAssertEqual(url, "/api/agent-runtime/runs/abc123/cancel/")
    }
    
    // MARK: - Auth Strategy Tests
    
    func testAuthStrategyDefaults() {
        XCTAssertEqual(AuthStrategy.token.defaultHeader, "Authorization")
        XCTAssertEqual(AuthStrategy.token.defaultPrefix, "Token")
        
        XCTAssertEqual(AuthStrategy.jwt.defaultHeader, "Authorization")
        XCTAssertEqual(AuthStrategy.jwt.defaultPrefix, "Bearer")
        
        XCTAssertEqual(AuthStrategy.anonymous.defaultHeader, "X-Anonymous-Token")
        XCTAssertEqual(AuthStrategy.anonymous.defaultPrefix, "")
    }
    
    // MARK: - Storage Tests
    
    func testInMemoryStorage() {
        let storage = InMemoryStorage()
        
        XCTAssertNil(storage.get("test_key"))
        
        storage.set("test_key", value: "test_value")
        XCTAssertEqual(storage.get("test_key"), "test_value")
        
        storage.set("test_key", value: nil)
        XCTAssertNil(storage.get("test_key"))
    }
    
    // MARK: - Message Tests
    
    func testMessageCreation() {
        let message = Message(
            role: .user,
            content: "Hello, world!"
        )
        
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "Hello, world!")
        XCTAssertEqual(message.type, .message)
        XCTAssertNotNil(message.id)
    }
    
    func testMessageEquality() {
        let message1 = Message(id: "test-id", role: .user, content: "Hello")
        let message2 = Message(id: "test-id", role: .user, content: "Hello")
        let message3 = Message(id: "test-id", role: .user, content: "Different")
        
        XCTAssertEqual(message1, message2)
        XCTAssertNotEqual(message1, message3)
    }
    
    // MARK: - APIMessage metadata decoding

    func testAPIMessageDecodesContentBlocksInMetadata() throws {
        // Mirror the shape the backend emits on conversation reload: a tool
        // message whose metadata carries persisted contentBlocks.
        let json = """
        {
          "role": "tool",
          "content": "Found a calming video",
          "toolCallId": "call_vid",
          "metadata": {
            "toolName": "get_video",
            "contentBlocks": [
              {"type": "video", "url": "https://example.com/a.mp4", "title": "Calm"}
            ]
          }
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(APIMessage.self, from: json)
        XCTAssertEqual(msg.role, "tool")
        XCTAssertEqual(msg.toolCallId, "call_vid")
        XCTAssertEqual(msg.metadata?.toolName, "get_video")
        guard case .video(let v) = msg.metadata?.contentBlocks?.first else {
            return XCTFail("expected video block")
        }
        XCTAssertEqual(v.url, "https://example.com/a.mp4")
        XCTAssertEqual(v.title, "Calm")
    }

    func testAPIMessageWithoutMetadataDecodesCleanly() throws {
        let json = """
        { "role": "user", "content": "hi" }
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(APIMessage.self, from: json)
        XCTAssertNil(msg.metadata)
    }

    // MARK: - Task State Tests

    func testTaskStateTransitions() {
        XCTAssertEqual(TaskState.notStarted.next, .inProgress)
        XCTAssertEqual(TaskState.inProgress.next, .complete)
        XCTAssertEqual(TaskState.complete.next, .notStarted)
        XCTAssertEqual(TaskState.cancelled.next, .notStarted)
    }
    
    func testTaskStateIcons() {
        XCTAssertEqual(TaskState.notStarted.icon, "○")
        XCTAssertEqual(TaskState.inProgress.icon, "◐")
        XCTAssertEqual(TaskState.complete.icon, "●")
        XCTAssertEqual(TaskState.cancelled.icon, "⊘")
    }

    // MARK: - Content Block Tests

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

        // Unknown types become .unknown, known types parse correctly
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

    // MARK: - Scroll Decision Tests

    func testScrollDecisionInitialLoadPinsBottomImmediately() {
        let action = ScrollDecision.onCountChange(
            oldCount: 0, newCount: 12,
            lastMessageIsUser: false, isNearBottom: false, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .pinBottom(delayMs: 0))
    }

    func testScrollDecisionUserSubmitDelaysForKeyboardAnimation() {
        // The submit path must wait past the UIKit keyboard-hide animation
        // (~250ms) before committing, otherwise the scroll lands on an
        // intermediate geometry and the row flies off. The exact delay value
        // is load-bearing — changing it is a deliberate behavioural change.
        let action = ScrollDecision.onCountChange(
            oldCount: 8, newCount: 9,
            lastMessageIsUser: true, isNearBottom: false, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .pinBottom(delayMs: ScrollDecision.userSubmitDelayMs))
        XCTAssertGreaterThanOrEqual(ScrollDecision.userSubmitDelayMs, 300)
    }

    func testScrollDecisionAssistantAppendNearBottomPinsImmediately() {
        // No keyboard to wait on for an assistant-driven append.
        let action = ScrollDecision.onCountChange(
            oldCount: 8, newCount: 9,
            lastMessageIsUser: false, isNearBottom: true, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .pinBottom(delayMs: 0))
    }

    func testScrollDecisionAssistantAppendScrolledUpDoesNothing() {
        let action = ScrollDecision.onCountChange(
            oldCount: 8, newCount: 9,
            lastMessageIsUser: false, isNearBottom: false, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .none)
    }

    func testScrollDecisionPrependPreservesAnchor() {
        let action = ScrollDecision.onCountChange(
            oldCount: 10, newCount: 20,
            lastMessageIsUser: false, isNearBottom: false,
            pendingAnchorId: "msg-99"
        )
        XCTAssertEqual(action, .preserveTopAnchor(id: "msg-99"))
    }

    func testScrollDecisionPrependWithoutPriorMessagesFallsThroughToPin() {
        // Edge case: oldCount==0 with a pending anchor. Treat as initial load,
        // not as prepend. (Anchor should have been cleared by the caller, but
        // test the pure logic anyway.)
        let action = ScrollDecision.onCountChange(
            oldCount: 0, newCount: 5,
            lastMessageIsUser: false, isNearBottom: false,
            pendingAnchorId: "msg-0"
        )
        XCTAssertEqual(action, .pinBottom(delayMs: 0))
    }

    func testScrollDecisionCountUnchangedDoesNothing() {
        let action = ScrollDecision.onCountChange(
            oldCount: 5, newCount: 5,
            lastMessageIsUser: true, isNearBottom: true, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .none)
    }

    func testScrollDecisionCountDecreasedDoesNothing() {
        // Retry/edit truncates messages. The decision layer does not
        // re-position the user; SwiftUI keeps the current scroll.
        let action = ScrollDecision.onCountChange(
            oldCount: 10, newCount: 7,
            lastMessageIsUser: true, isNearBottom: true, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .none)
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
}

