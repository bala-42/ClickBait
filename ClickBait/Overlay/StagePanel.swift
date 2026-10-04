import AppKit

/// A see-through, click-through window covering one whole screen, with a view that moves
/// around inside it. Moving a window every frame cost a synchronous round trip to the
/// window server (`NSWindow setFrame` → a CA fence): when Ollama kept the GPU busy, each
/// move waited and the companion stuttered (90–300 ms stalls in a 6 s sample). Moving a
/// view inside a still window is only a Core Animation update. The window itself moves
/// only when the content crosses to another screen.
@MainActor
final class StagePanel {
    let panel: NSPanel
    let content: NSView

    init(content: NSView, size: CGSize, makePanel: (CGRect) -> NSPanel) {
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel = makePanel(screen)
        let stage = NSView(frame: CGRect(origin: .zero, size: screen.size))
        stage.wantsLayer = true
        stage.autoresizingMask = [.width, .height]
        panel.contentView = stage
        content.frame = CGRect(origin: .zero, size: size)
        stage.addSubview(content)
        self.content = content
    }

    /// The content's frame in global AppKit coordinates.
    var contentFrame: CGRect {
        content.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    /// Puts the content's bottom-left at `origin` (global AppKit), on the screen holding
    /// `anchor` (the point the content belongs to: the cursor, a target).
    func setOrigin(_ origin: CGPoint, anchor: CGPoint) {
        if !panel.frame.contains(anchor),
           let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) ?? NSScreen.main {
            panel.setFrame(screen.frame, display: false)
        }
        let local = CGPoint(x: origin.x - panel.frame.minX, y: origin.y - panel.frame.minY)
        if content.frame.origin != local { content.setFrameOrigin(local) }
    }
}
