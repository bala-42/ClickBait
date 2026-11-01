import AppKit
import SwiftUI
import Testing
@testable import ClickBait

/// Studio's voice beam at three loudnesses, drawn with SwiftUI's own renderer (blur and glow
/// included), on the prompter's black (ClickBaitTests-studio/beam-*.png).
@MainActor
struct RingRenderTests {
    @Test func beamDraws() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-studio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, level) in [("silent", 0.0), ("talking", 0.45), ("loud", 0.9)] {
            let view = ZStack(alignment: .bottom) {
                UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous).fill(Color.black)
                QuicksilverRing(level: level, reduceMotion: false)
                Text("pauses when you stop speaking\nand picks up right where you left off.")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).padding(.bottom, 40)
            }
            .frame(width: 520, height: 170)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous))
            .padding(20).background(Color(red: 0.35, green: 0.37, blue: 0.75))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "beam-\(name).png"))
        }
    }
}
