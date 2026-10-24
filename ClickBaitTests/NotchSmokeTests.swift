import AppKit
import ClickBaitCore
import SwiftUI
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
        // A conversation asked in the notch: the dark chat bubble fills the taller Ask tab.
        let chat = ChatModel()
        chat.addUser("write a palindrome check in python")
        chat.setAssistant("Here's a short one.\n\n```python\ndef is_palindrome(word):\n    word = word.lower()\n    return word == word[::-1]\n```")
        let rep = try #require(notch.snapshot(.expanded, tab: .ask, chat: chat), "chat")
        #expect(rep.size.height == CGFloat(NotchPanel.chatSize.height + 30), "chat height")
        #expect(Self.colours(in: rep) >= 12, "chat looks blank")
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "chat.png"))
        // The ⓘ card hangs under its button over the cards, the panel keeping its size.
        let keys = try #require(notch.snapshot(.expanded, keys: true), "keys")
        #expect(keys.size.height == CGFloat(NotchPanel.expandedSize.height + 30), "keys height")
        try keys.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "keys.png"))
        // The volume HUD's Pac-Man level, at 60 %.
        let hud = try #require(notch.snapshot(.collapsed, hud: (0.6, false)), "hud")
        #expect(Self.colours(in: hud) >= 6, "hud looks blank")
        try hud.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "hud.png"))
        // The bean asleep: X-ray body, z eyes (both pairs).
        for (name, eyes) in [("sleep", Bean.EyePair.both(.z)), ("sleep-wink", Bean.EyePair(.dash(), .z))] {
            let renderer = ImageRenderer(content: BeanFace(mood: .sleepy, eyes: eyes, size: 76, badge: false)
                .padding(20).background(Color.black))
            renderer.scale = 2
            let image = try #require(renderer.nsImage, "\(name)")
            try image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
        }
        // The brightness sky through the day: night, dawn, sunrise, noon.
        for level in [0.05, 0.3, 0.5, 1.0] {
            let sky = try #require(notch.snapshot(.collapsed, sky: level), "sky \(level)")
            #expect(Self.colours(in: sky) >= 6, "sky \(level) looks blank")
            try sky.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "sky-\(Int(level * 100)).png"))
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
