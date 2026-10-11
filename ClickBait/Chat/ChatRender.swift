#if DEBUG
import AppKit
import SwiftUI

/// Renders the chat in a few states over a busy, colourful picture, to compare looks
/// (Debug builds only): `open --env CLICKBAIT_RENDER_CHAT=<folder> --env CLICKBAIT_RENDER_TAG=after ClickBait.app`
/// writes chat-<tag>-<state>.png at 2× and quits, before anything else starts.
@MainActor
enum ChatRender {
    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["CLICKBAIT_RENDER_CHAT"] else { return }
        let tag = environment["CLICKBAIT_RENDER_TAG"] ?? "render"
        let scene = CGSize(width: 760, height: 760)
        let origin = CGPoint(x: 120, y: 60)
        let background = busyPicture(size: scene)
        for (name, model) in states() {
            let view = ZStack(alignment: .topLeading) {
                Image(nsImage: background).resizable().frame(width: scene.width, height: scene.height)
                ChatView(model: model)
                    .environment(\.chatBackdrop, ChatBackdrop(image: background, origin: origin, size: scene))
                    .environment(\.chatRenderHover, name == "hover")
                    .environment(\.chatRenderCopied, name == "long")
                    .offset(x: origin.x, y: origin.y)
            }
            .frame(width: scene.width, height: scene.height, alignment: .topLeading)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: folder).appending(path: "chat-\(tag)-\(name).png"))
        }
        exit(0)
    }

    private static func states() -> [(String, ChatModel)] {
        let empty = ChatModel()
        empty.draft = "how do I undo my last commit"

        let short = ChatModel()
        short.messages = [.init(role: .user, text: "where's the share button?"),
                          .init(role: .assistant, text: "Top right of the toolbar — the square with the arrow. I pointed at it.")]

        let long = ChatModel()
        long.messages = [
            .init(role: .user, text: "why does this crash?"),
            .init(role: .assistant, text: """
                The list of prices is **empty**, so `len(prices)` is 0 and Python can't divide by zero. \
                Guard the average so an empty cart gives 0 instead of a crash — see the \
                [Python docs](https://docs.python.org/3/library/exceptions.html) on `ZeroDivisionError`.

                ```python
                total = sum(prices) / len(prices) if prices else 0  # an empty cart is fine now, and this line is long enough to wrap
                ```

                Then run it again with an empty cart to check.
                """),
        ]

        let busy = ChatModel()
        busy.messages = [.init(role: .user, text: "and in JavaScript?")]
        busy.isBusy = true
        busy.draft = "and TypeScript"
        return [("empty", empty), ("short", short), ("long", long), ("busy", busy), ("hover", short)]
    }

    /// Colour, shapes and small text in black and white: hard to read through, on purpose.
    private static func busyPicture(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let colours: [NSColor] = [.systemPink, .systemYellow, .systemTeal, .systemPurple, .systemOrange, .systemGreen, .white, .systemBlue]
        NSGradient(colors: [.systemIndigo, .systemOrange])?.draw(in: NSRect(origin: .zero, size: size), angle: 35)
        var seed: UInt64 = 42
        func random() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
        for index in 0..<70 {
            let diameter = 30 + random() * 160
            colours[index % colours.count].withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: random() * size.width - 40, y: random() * size.height - 40, width: diameter, height: diameter)).fill()
        }
        for row in stride(from: 0.0, to: size.height, by: 26) {
            let text = "Lorem ipsum dolor sit amet — 12:45 · Inbox (3) · build failed · ZeroDivisionError"
            let colour: NSColor = Int(row / 26) % 2 == 0 ? .black : .white
            (text as NSString).draw(at: NSPoint(x: 8 + (row.truncatingRemainder(dividingBy: 52)), y: row),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: colour])
        }
        image.unlockFocus()
        return image
    }
}
#endif
