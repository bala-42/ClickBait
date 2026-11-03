import AppKit
import ClickBaitCore
import SwiftUI

/// Four round buttons beside the open notch, two each side (user's ask, 2026-11-02, after
/// Vorssaint's): the gallery and the timer on the left, settings and sound cues on the right.
/// Black, with the Home text's white; shown on Home and on the pages they open, tucked back
/// into the notch (sliding in and fading) on Lookup, Shelf, Studio, the player and Settings.
@MainActor
final class NotchBubbles {
    struct Bubble: Identifiable {
        let id: String
        let symbol: String
        let label: String
        var on = false
        let action: () -> Void
    }

    static let diameter: CGFloat = 40
    static let spacing: CGFloat = 10
    /// From the notch's side to the bubbles.
    static let gap: CGFloat = 14
    /// From the notch's top to the first bubble: under the header.
    static let top: CGFloat = 40

    private var left: NSPanel?
    private var right: NSPanel?
    private(set) var shown = false

    /// The bubbles' frames while shown, for the pointer: on a bubble is still on the notch.
    var frames: [CGRect] { shown ? [left, right].compactMap { $0?.frame } : [] }

    func update(visible: Bool, beside notch: CGRect, left leftBubbles: [Bubble], right rightBubbles: [Bubble]) {
        let height = Self.diameter * 2 + Self.spacing
        let y = notch.maxY - Self.top - height
        let leftFrame = CGRect(x: notch.minX - Self.gap - Self.diameter, y: y, width: Self.diameter, height: height)
        let rightFrame = CGRect(x: notch.maxX + Self.gap, y: y, width: Self.diameter, height: height)
        if visible {
            left = show(left, at: leftFrame, from: notch.minX + 8, bubbles: leftBubbles)
            right = show(right, at: rightFrame, from: notch.maxX - 8 - Self.diameter, bubbles: rightBubbles)
        } else {
            hide(left, toward: notch.minX + 8)
            hide(right, toward: notch.maxX - 8 - Self.diameter)
        }
        shown = visible
        if visible { report() }
    }

    /// Half a second after showing: whether macOS really shows them, on this Space, over which app.
    private func report() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, shown, let left else { return }
            let app = NSWorkspace.shared.frontmostApplication
            var fullScreen = "?"
            if let pid = app?.processIdentifier {
                let element = AXUIElementCreateApplication(pid)
                var window: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window {
                    var value: CFTypeRef?
                    AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &value)  // an AXUIElement, as asked
                    fullScreen = (value as? Bool).map { $0 ? "yes" : "no" } ?? "?"
                }
            }
            Log.app.notice("Bubbles check: visible \(left.occlusionState.contains(.visible), privacy: .public), on this Space \(left.isOnActiveSpace, privacy: .public), alpha \(left.alphaValue, privacy: .public), level \(left.level.rawValue, privacy: .public), over \(app?.localizedName ?? "?", privacy: .public) full screen \(fullScreen, privacy: .public)")
        }
    }

    private func show(_ existing: NSPanel?, at frame: CGRect, from tuckedX: CGFloat, bubbles: [Bubble]) -> NSPanel {
        let panel = existing ?? Self.makePanel()
        panel.contentView = NSHostingView(rootView: BubbleColumn(bubbles: bubbles))
        guard !(shown && panel.isVisible) else {
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            // Kept in front: a full-screen app's toolbar, sliding down as the pointer reaches the
            // top to open the notch, came over them (user's reports, 2026-11-03).
            panel.orderFrontRegardless()
            return panel
        }
        // Out of the notch: from tucked behind its side to beside it.
        panel.setFrame(CGRect(x: tuckedX, y: frame.minY, width: frame.width, height: frame.height), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        return panel
    }

    private func hide(_ panel: NSPanel?, toward tuckedX: CGFloat) {
        guard let panel, panel.isVisible, shown else { return }
        var tucked = panel.frame
        tucked.origin.x = tuckedX
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(tucked, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = BubblePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the notch's own layer, as the dock's tiles: nothing that comes over the menu bar's
        // strip (a full-screen app's sliding toolbar) covers them.
        panel.level = WindowLayers.dock
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.sharingType = .none  // never in screenshots, as the notch
        panel.isReleasedWhenClosed = false
        return panel
    }

    private final class BubblePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
}

private struct BubbleColumn: View {
    let bubbles: [NotchBubbles.Bubble]

    var body: some View {
        VStack(spacing: NotchBubbles.spacing) {
            ForEach(bubbles) { bubble in
                Button(action: bubble.action) {
                    Image(systemName: bubble.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NotchPalette.text)
                        .frame(width: NotchBubbles.diameter, height: NotchBubbles.diameter)
                        .background(Circle().fill(Color.black))
                        // A rim clear enough to find on dark apps (Chrome's toolbar is as black as the
                        // bubble: they vanished there; user's report, 2026-11-03).
                        .overlay(Circle().strokeBorder(Color.white.opacity(bubble.on ? 0.6 : 0.3), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(PlayerPressStyle())
                .help(bubble.label)
                .accessibilityLabel(bubble.label)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
