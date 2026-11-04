import AppKit
import SwiftUI

/// A light from behind the notch (user's asks, 2026-11-04: "coming from behind the notch", not
/// filling it): a click-through window just behind the notch's, a little larger, where a soft
/// blurred shape the notch's size glows and pulses — the black notch in front, the colour spilling
/// out around it onto the screen. Ruby while the timer's alarm rings; sea-glass teal for a moment
/// when a Pomodoro phase ends. Reduce Motion: steady.
@MainActor
final class NotchGlow {
    static let ruby = Color(hex: 0xE0115F)
    static let calm = Color(hex: 0x5FC9B8)
    /// How far the light reaches past the notch.
    static let reach: CGFloat = 44

    private var panel: NSPanel?
    private var color: Color?
    private var fade: Task<Void, Never>?

    var lit: Bool { color != nil }

    /// Light it (for `seconds`, or until `dim()`), behind `notch` (its window's frame).
    func light(_ color: Color, behind notch: NSWindow, for seconds: Double? = nil) {
        self.color = color
        follow(notch)
        fade?.cancel()
        if let seconds {
            fade = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.dim()
            }
        }
    }

    /// Faded out, left on screen (as the notch's bubbles: one brought back over a full-screen
    /// app stayed hidden there).
    func dim() {
        fade?.cancel()
        color = nil
        panel?.alphaValue = 0
    }

    /// Keeps behind the notch as it grows, shrinks or moves.
    func follow(_ notch: NSWindow) {
        guard let color else { return }
        let reach = Self.reach
        let frame = CGRect(x: notch.frame.minX - reach, y: notch.frame.minY - reach,
                           width: notch.frame.width + 2 * reach, height: notch.frame.height + reach)
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: GlowView(color: color, notch: notch.frame.size, reach: reach))
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
        panel.order(.below, relativeTo: notch.windowNumber)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = WindowLayers.notch
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.sharingType = .none  // never in screenshots, as the notch
        return panel
    }
}

private struct GlowView: View {
    let color: Color
    let notch: CGSize
    let reach: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18)
            .fill(color)
            .frame(width: notch.width, height: notch.height)
            .blur(radius: reach / 2.6)
            .opacity(bright ? 0.95 : 0.55)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                guard !reduceMotion else { bright = true; return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}
