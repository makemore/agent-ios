import XCTest
import SwiftUI
import AgentClient
@testable import AgentFrontend

/// Render the real panel over a conspicuous transcript colour. No backend,
/// account, speech or permission requests; pixel checks catch clear surfaces
/// that source-wiring and history-state tests cannot detect.
@MainActor
final class SidebarRenderingTests: XCTestCase {
    func testNeutralPanelIsOpaqueInLightAndDarkMode() throws {
        for width in [320, 390, 1024] {
            for scheme in [ColorScheme.light, .dark] {
                let image = try render(appearance: .neutral, scheme: scheme, width: width)
                let panel = try pixel(image, x: 20, y: 400)
                XCTAssertEqual(panel.r, panel.g, accuracy: 0.02, "Red transcript must not show through")
                XCTAssertEqual(panel.g, panel.b, accuracy: 0.02)
                if scheme == .light { XCTAssertGreaterThan(panel.r, 0.85) }
                else { XCTAssertLessThan(panel.r, 0.3) }
                try assertScrim(image)
            }
        }
    }

    func testClassicPanelAlsoHasAnOpaqueBase() throws {
        let image = try render(appearance: .classic, scheme: .light)
        let panel = try pixel(image, x: 20, y: 400)
        XCTAssertGreaterThan(panel.g, 0.85)
        XCTAssertEqual(panel.r, panel.g, accuracy: 0.02)
        try assertScrim(image)
    }

    func testCustomBackgroundIsPreservedAndTranslucentTintCompositesOverBase() throws {
        for opacity in [1.0, 0.5] {
            var appearance = ChatAppearance.neutral
            appearance.background = Color(.sRGB, red: 0, green: 0, blue: 1, opacity: opacity)
            let image = try render(appearance: appearance, scheme: .light)
            let panel = try pixel(image, x: 20, y: 400)
            XCTAssertGreaterThan(panel.b, 0.95, "Custom blue must not be dimmed by the scrim")
            XCTAssertEqual(panel.r, panel.g, accuracy: 0.02, "Tint must blend with an opaque neutral base, not the red transcript")
            if opacity == 1 { XCTAssertLessThan(panel.r, 0.05) }
            else { XCTAssertGreaterThan(panel.g, 0.4) }
            try assertScrim(image)
        }
    }

    private func render(appearance: ChatAppearance, scheme: ColorScheme, width: Int = 390) throws -> CGImage {
        var config = ChatWidgetConfig(backendUrl: "https://example.test", agentKey: "sidebar-rendering")
        config.appearance = appearance
        config.sidebar.showRecents = false
        config.sidebar.items = []
        let storage = InMemoryStorage()
        let api = APIClient(config: config, storage: storage)
        let model = ChatViewModel(config: config, apiClient: api, storage: storage)
        let content = ZStack(alignment: .leading) {
            Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
            ChatSidebarView(viewModel: model, config: config, onDismiss: {},
                            onNewChat: {}, onSelectConversation: { _ in })
        }
        .frame(width: CGFloat(width), height: 800)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage, "Sidebar must render without an app host")
    }

    private func assertScrim(_ image: CGImage) throws {
        let outside = try pixel(image, x: image.width - 5, y: 400)
        XCTAssertEqual(outside.r, 0.65, accuracy: 0.06, "Backdrop dims only the exposed chat")
        XCTAssertLessThan(outside.g, 0.02)
        XCTAssertLessThan(outside.b, 0.02)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: Double, g: Double, b: Double) {
        // Normalize pixel layout instead of assuming ImageRenderer's channel
        // order or colour space. The fixture's full canvas is opaque.
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (y * image.width + x) * 4
        return (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255,
                Double(bytes[offset + 2]) / 255)
    }
}