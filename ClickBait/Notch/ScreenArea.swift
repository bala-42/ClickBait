import AppKit
import ClickBaitCore
import OSLog
import SwiftUI
import Vision

/// Reading part of the screen (Capture's Copy text): the area's picture, and its text or QR
/// code, read on this Mac.
enum ScreenArea {
    /// That part of the screen (global points), at full resolution; ClickBait's own windows left out.
    static func picture(of area: CGRect, blocklist: AppBlocklist, with capturer: ScreenCapturer = ScreenCapturer()) async -> CGImage? {
        guard let capture = try? await capturer.captureDisplayUnderCursor(excluding: blocklist, at: NSPoint(x: area.midX, y: area.midY)) else { return nil }
        let scale = capture.backingScale
        let crop = CGRect(x: (area.minX - capture.displayFrame.minX) * scale,
                          y: (capture.displayFrame.maxY - area.maxY) * scale,
                          width: area.width * scale, height: area.height * scale).integral
        return capture.image.cropping(to: crop)
    }

    /// Copy text (user's ask, 2026-11-02, after Vorssaint's): a QR code's contents, else the
    /// area's text, line by line; nil when there's nothing to read.
    static func copyableText(in image: CGImage) async -> (text: String, isCode: Bool)? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        if let code = request.results?.first?.payloadStringValue, !code.isEmpty { return (code, true) }
        let text = await TextReader.read(image).map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (text, false)
    }
}

/// Drag a box around what to watch (Esc cancels): a dimmed screen with the box clear.
@MainActor
enum WatchAreaPicker {
    private static var panels: [NSPanel] = []
    private static var done: ((CGRect?) -> Void)?

    static func pick(_ completion: @escaping (CGRect?) -> Void) {
        finish(nil)
        done = completion
        panels = NSScreen.screens.map { screen in
            let panel = PickerPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .screenSaver
            panel.ignoresMouseEvents = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = PickerView(frame: CGRect(origin: .zero, size: screen.frame.size), screenOrigin: screen.frame.origin)
            panel.orderFrontRegardless()
            panel.makeKey()
            return panel
        }
        NSCursor.crosshair.push()
    }

    static func finish(_ area: CGRect?) {
        guard !panels.isEmpty || done != nil else { return }
        if !panels.isEmpty { NSCursor.pop() }
        panels.forEach { $0.orderOut(nil) }
        panels = []
        let completion = done
        done = nil
        completion?(area)
    }

    private final class PickerPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private final class PickerView: NSView {
        let screenOrigin: CGPoint
        private var start: CGPoint?
        private var current: CGPoint?

        init(frame: CGRect, screenOrigin: CGPoint) {
            self.screenOrigin = screenOrigin
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { nil }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func keyDown(with event: NSEvent) { if event.keyCode == 53 { WatchAreaPicker.finish(nil) } }
        override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); current = start; needsDisplay = true }
        override func mouseDragged(with event: NSEvent) { current = convert(event.locationInWindow, from: nil); needsDisplay = true }
        override func mouseUp(with event: NSEvent) {
            guard let box = box, box.width > 12, box.height > 8 else { WatchAreaPicker.finish(nil); return }
            WatchAreaPicker.finish(box.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y))
        }

        private var box: CGRect? {
            guard let start, let current else { return nil }
            return CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            guard let box else { return }
            NSColor.clear.setFill()
            box.fill(using: .copy)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}
