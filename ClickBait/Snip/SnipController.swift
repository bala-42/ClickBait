import AppKit
import ClickBaitCore

/// Hold ⌥⌘ to mark part of the screen (roadmap phase C). Holding it for `armDelay`
/// arms the snip: the companion turns red (with a trackpad tick) and a transparent
/// layer covers every screen — moving the cursor traces a red line, clicking and
/// dragging draws a red box (the click never reaches the app below). Letting go
/// before then is a plain tap (explain), and the mouse was never taken over.
@MainActor
final class SnipController {
    /// Armed (or not any more): the companion turns Strawberry Red.
    var onMarkingChange: ((Bool) -> Void)?

    private var tracker: SnipTracker?
    private var panels: [NSPanel] = []
    private var timer: Timer?
    private var startedAt = Date()
    /// When the keys were first seen up without a key-up event arriving.
    private var keysUpSince: Date?
    private var isMarking = false {
        didSet { if isMarking != oldValue { onMarkingChange?(isMarking) } }
    }

    /// Never block the screen for longer than this, whatever happened to the keys.
    private static let maxDuration: TimeInterval = 60
    /// The key-up event lags the hardware state by a few milliseconds; only give up on
    /// it after this long, or the failsafe throws away the drawing just before release.
    private static let missedKeyUpGrace: TimeInterval = 0.5
    /// How long ⌥⌘ must be held before snipping starts. Short enough not to feel like
    /// waiting, long enough that a quick tap never turns red.
    static let armDelay: TimeInterval = 0.4

    /// ⌥⌘ is down (armed or not yet).
    var isActive: Bool { timer != nil }
    /// Held long enough: the red layer is up and tracking.
    var isArmed: Bool { tracker != nil }

    func begin() {
        cancel()
        startedAt = Date()
        keysUpSince = nil
        // A timer rather than mouse-moved events: those only arrive for apps that ask.
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func arm() {
        tracker = SnipTracker(start: Self.quartzMouse())
        panels = NSScreen.screens.map(makePanel)
        panels.forEach { $0.orderFrontRegardless() }
        isMarking = true
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        Log.input.notice("Snip armed")
    }

    /// ⌥⌘ was let go: what did the user mark? `.tap` when nothing was (or it wasn't armed).
    func end() -> SnipDecision {
        let decision = tracker?.decide() ?? .tap
        cancel()
        return decision
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        tracker = nil
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels = []
        isMarking = false
    }

    // MARK: - Tracking

    private func tick() {
        guard timer != nil else { return }
        // Failsafe: if the key-up was missed, don't leave a layer eating every click.
        let flags = NSEvent.modifierFlags
        let held = flags.contains(.option) && flags.contains(.command)
        if held {
            keysUpSince = nil
        } else {
            let since = keysUpSince ?? Date()
            keysUpSince = since
            // Still waiting for the key-up event; don't extend the drawing meanwhile.
            guard Date().timeIntervalSince(since) > Self.missedKeyUpGrace else { return }
        }
        if !held || Date().timeIntervalSince(startedAt) > Self.maxDuration {
            Log.input.notice("Snip ended without a key-up; cancelling")
            cancel()
            return
        }
        guard tracker != nil else {
            if Date().timeIntervalSince(startedAt) >= Self.armDelay { arm() }
            return
        }
        let before = tracker?.traceLength
        tracker?.cursorMoved(to: Self.quartzMouse())
        if tracker?.traceLength != before { redraw() }
    }

    fileprivate func mouseDown() {
        tracker?.mouseDown(at: Self.quartzMouse())
        redraw()
    }

    fileprivate func mouseDragged() {
        tracker?.mouseDragged(to: Self.quartzMouse())
        redraw()
    }

    private func redraw() {
        for panel in panels { panel.contentView?.needsDisplay = true }
    }

    /// What the canvases draw, in global Quartz points.
    fileprivate var drawing: (trace: [Point], box: Rect?)? {
        guard let tracker, tracker.isMarking else { return nil }
        return (tracker.box == nil ? tracker.trace : [], tracker.box)
    }

    static func quartzMouse() -> Point {
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return Point(x: mouse.x, y: primaryHeight - mouse.y)
    }

    // MARK: - Panels

    private func makePanel(for screen: NSScreen) -> NSPanel {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false  // catches the box drag so the app below never sees it
        // Just under the companion, so the red triangle stays visible on top.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let quartzOrigin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
        panel.contentView = SnipCanvasView(controller: self, quartzOrigin: quartzOrigin)
        panel.setFrame(screen.frame, display: false)
        return panel
    }
}

/// Draws the trace or box on one screen and forwards the mouse to the controller.
private final class SnipCanvasView: NSView {
    weak var controller: SnipController?
    /// This screen's top-left in global Quartz points.
    let quartzOrigin: CGPoint

    static let red = NSColor(srgbRed: 0.98, green: 0.22, blue: 0.36, alpha: 1)

    init(controller: SnipController, quartzOrigin: CGPoint) {
        self.controller = controller
        self.quartzOrigin = quartzOrigin
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // matches Quartz: y grows downward
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown() }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged() }

    override func draw(_ dirtyRect: NSRect) {
        guard let drawing = controller?.drawing else { return }
        let local = { (p: Point) in CGPoint(x: p.x - self.quartzOrigin.x, y: p.y - self.quartzOrigin.y) }
        let shadow = NSShadow()
        shadow.shadowColor = Self.red.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 8
        shadow.set()
        if let box = drawing.box {
            let rect = CGRect(origin: local(Point(x: box.x, y: box.y)), size: CGSize(width: box.width, height: box.height))
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            Self.red.withAlphaComponent(0.1).setFill()
            path.fill()
            Self.red.setStroke()
            path.lineWidth = 2.5
            path.stroke()
        } else if drawing.trace.count > 1 {
            let path = NSBezierPath()
            path.move(to: local(drawing.trace[0]))
            drawing.trace.dropFirst().forEach { path.line(to: local($0)) }
            path.lineWidth = 3.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            Self.red.setStroke()
            path.stroke()
        }
    }
}
