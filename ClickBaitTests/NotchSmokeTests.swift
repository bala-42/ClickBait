import AppKit
import ClickBaitCore
import Testing
@testable import ClickBait

/// UI smoke tests: every notch surface draws in a real (offscreen, never shown) window, at the
/// size its layout gives, with something on it. AppKit-backed views (the shelf) draw too. The
/// PNGs go to the temporary folder to look at; none are kept.
@MainActor
struct NotchSmokeTests {
    private static let cases: [(name: String, state: NotchPanel.State, tab: NotchController.Model.Tab, greeting: Bool)] = [
        ("peek", .peek, .home, false),
        ("home", .expanded, .home, false),
        ("greeting", .expanded, .home, true),
        ("ask", .expanded, .ask, false),
        ("shelf", .expanded, .shelf, false),
        ("settings", .expanded, .settings, false),
    ]

    @Test func everySurfaceDraws() throws {
        let settings = AppSettings()
        let notch = NotchController(settings: settings, speech: SpeechModelManager(settings: settings),
                                    speaker: Speaker(settings: settings))
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-notch")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in Self.cases {
            let rep = try #require(notch.snapshot(item.state, tab: item.tab, greeting: item.greeting), "\(item.name)")
            let look = NotchPanel.shape(item.state, notch: nil, activity: false, hud: false,
                                        shelf: item.tab == .shelf, settings: item.tab == .settings)
            #expect(rep.size.width == CGFloat(look.width + 2 * NotchPanel.ear + 60), "\(item.name) width")
            #expect(Self.colours(in: rep) >= 12, "\(item.name) looks blank")
            try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(item.name).png"))
        }
    }

    /// How many different colours a coarse sample finds: a blank render has one or two.
    private static func colours(in rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
            }
        }
        return seen.count
    }
}
