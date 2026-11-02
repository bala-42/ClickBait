import ClickBaitCore
import SwiftUI
import Testing
@testable import ClickBait

/// Draws the shelf's hover pills for each kind of file, to look at (opt-in: `TEST_RUNNER_CLICKBAIT_RENDER_DIR`).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_RENDER_DIR"] != nil))
struct ShelfPillsRenderTests {
    @Test func render() throws {
        let rows = VStack(alignment: .leading, spacing: 10) {
            ForEach(["/x/holiday photos.zip", "/x/shampoo_input (1).mov", "/x/beach.png", "/x/notes.pdf"], id: \.self) { path in
                ShelfActionPills(file: URL(fileURLWithPath: path)).frame(width: 230, height: 16)
            }
        }
        .padding(12)
        .background(Color(red: 0x14 / 255, green: 0x15 / 255, blue: 0x18 / 255))
        .foregroundStyle(.white)
        let renderer = ImageRenderer(content: rows)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLICKBAIT_RENDER_DIR"]!).appending(path: "shelf-pills.png"))
    }

    @Test func renderAirDropBean() throws {
        let row = HStack(spacing: 22) {
            BeanFace(mood: .idle, eyes: Bean.eyes(for: .idle, avoiding: nil), size: 40)
            AirDropBean(look: .ready, size: 40)
            AirDropBean(look: .eager, size: 40)
            AirDropBean(look: .problem, size: 40)
        }
        .padding(16)
        .background(Color(red: 0x14 / 255, green: 0x15 / 255, blue: 0x18 / 255))
        let renderer = ImageRenderer(content: row)
        renderer.scale = 3
        let image = try #require(renderer.nsImage)
        let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLICKBAIT_RENDER_DIR"]!).appending(path: "airdrop-bean.png"))
    }

    @Test func renderTimer() throws {
        let view = NotchTimerView(interactive: false)
            .frame(width: 600, height: 110)
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLICKBAIT_RENDER_DIR"]!).appending(path: "timer.png"))
    }
}
