import AppKit
import ClickBaitCore
import Observation
import OSLog
import SwiftUI

/// Watch (user's ask, 2026-11-02): an area of the screen read every 2 s (`TextReader`, on this
/// Mac; a picture's rough fingerprint where it holds no text) until `ScreenWatch` says it's done,
/// then a pill by the cursor. Gives up after 2 hours. Nothing is kept but the last reading.
@MainActor @Observable
final class ScreenWatcher {
    static let shared = ScreenWatcher()

    private(set) var area: CGRect?
    private(set) var rule: ScreenWatch.Rule?
    private(set) var reading = ""
    private(set) var startedAt: Date?
    /// Said when it's done ("watch: it says “Done” ✓"), by the app delegate.
    @ObservationIgnored var onDone: ((String) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let capturer = ScreenCapturer()

    var watching: Bool { task != nil }

    private init() {}

    func start(area: CGRect, rule: ScreenWatch.Rule, blocklist: AppBlocklist) {
        stop()
        (self.area, self.rule, reading, startedAt) = (area, rule, "", Date())
        var watch = ScreenWatch(rule: rule)
        Log.app.notice("Watch started: \(rule.summary, privacy: .public)")
        task = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(2 * 3600)
            while let self, !Task.isCancelled, Date() < deadline {
                if let text = await self.read(area, blocklist: blocklist) {
                    self.reading = text
                    if let why = watch.see(text) {
                        self.task = nil
                        self.onDone?("watch: \(why) ✓")
                        Log.app.notice("Watch done: \(why, privacy: .public)")
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The area's text (or, holding none, its picture's fingerprint), or nil when it couldn't be read.
    private func read(_ area: CGRect, blocklist: AppBlocklist) async -> String? {
        guard let capture = try? await capturer.captureDisplayUnderCursor(excluding: blocklist, at: NSPoint(x: area.midX, y: area.midY)) else { return nil }
        let scale = capture.backingScale
        let crop = CGRect(x: (area.minX - capture.displayFrame.minX) * scale,
                          y: (capture.displayFrame.maxY - area.maxY) * scale,
                          width: area.width * scale, height: area.height * scale).integral
        guard let image = capture.image.cropping(to: crop) else { return nil }
        let text = await TextReader.read(image).map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Self.fingerprint(image) : text
    }

    /// A 16 × 16 grey thumbnail as text: the same while the picture holds still.
    private static func fingerprint(_ image: CGImage) -> String {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return "" }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        // Coarse steps, so the picture's noise doesn't count as a change.
        return "picture:" + pixels.map { String($0 / 32) }.joined()
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

/// The Watch page: what to wait for, then a box drawn around it; while watching, the rule, the
/// last reading and Stop.
struct WatchPage: View {
    @Bindable var watcher = ScreenWatcher.shared
    let pick: (ScreenWatch.Rule) -> Void
    @State private var kind = 0
    @State private var value = ""

    private var rule: ScreenWatch.Rule? {
        switch kind {
        case 0: .changes
        case 1: .finishes
        case 2: value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .says(value.trimmingCharacters(in: .whitespaces))
        default: ScreenWatch.number(in: value).map(ScreenWatch.Rule.reaches)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if watcher.watching, let rule = watcher.rule {
                HStack {
                    Image(systemName: "eye").foregroundStyle(NotchPalette.text)
                    Text("Watching · tell you \(rule.summary)").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("Stop") { watcher.stop() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(CompanionTone.problem)
                }
                Text(watcher.reading.hasPrefix("picture:") ? "No text there: watching the picture." : watcher.reading.isEmpty ? "Reading…" : "Reads: \(watcher.reading)")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary).lineLimit(2)
                if let started = watcher.startedAt {
                    Text("since \(started.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(NotchPalette.tertiary)
                }
            } else {
                Picker("", selection: $kind) {
                    Text("Changes").tag(0)
                    Text("Finishes").tag(1)
                    Text("Says…").tag(2)
                    Text("Reaches…").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack(spacing: 8) {
                    if kind >= 2 {
                        TextField(kind == 2 ? "Done" : "100", text: $value)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .padding(.horizontal, 8).frame(height: 26)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Spacer()
                    Button { if let rule { pick(rule) } } label: {
                        Label("Drag a box around it", systemImage: "viewfinder").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(NotchPalette.text.opacity(rule == nil ? 0.05 : 0.14), in: Capsule())
                    }
                    .buttonStyle(.plain).disabled(rule == nil)
                }
                Text("ClickBait reads that part of the screen every 2 seconds, on this Mac, for up to 2 hours.")
                    .font(.system(size: 10)).foregroundStyle(NotchPalette.tertiary)
            }
        }
        .foregroundStyle(NotchPalette.text)
    }
}
