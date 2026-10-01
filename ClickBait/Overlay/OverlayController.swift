import AppKit
import ClickBaitCore
import SwiftUI

/// Owns the transparent overlay panels (one per screen) and the companion bubble that
/// follows the cursor. Click-through everywhere; never takes focus.
@MainActor
final class OverlayController {
    /// Answers stay up at least this long, longer for longer text (reading time).
    static let minimumAnswerLifetime = 6.0
    static let maximumAnswerLifetime = 25.0

    let model = OverlayModel()
    /// Called when the user dismisses an answer (click, Escape, or timeout).
    var onDismiss: (() -> Void)?
    /// Called when Escape is pressed while ClickBait is listening or thinking.
    var onCancel: (() -> Void)?
    /// Whether the Sandevistan speed trail is on (Settings); Reduce Motion always wins.
    var trailEnabled: () -> Bool = { true }

    private var screenPanels: [NSPanel] = []
    private var bubblePanel: NSPanel?
    private var bubbleHost: NSHostingView<CompanionBubbleView>?
    private var monitors: [Any] = []
    private var dismissTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    func start() {
        rebuildScreenPanels()
        makeBubblePanel()
        installMonitors()
        startMotion()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildScreenPanels() }
        }
        moveBubble(to: NSEvent.mouseLocation)
    }

    // MARK: - State

    func show(_ state: AskState, heard: String? = nil) {
        switch state {
        case .idle:
            if case .answer = model.bubble { return }  // the answer stays until dismissed
            model.bubble = .idle
        case .listening:
            setCompanionHidden(false)
            dismissTask?.cancel()
            clearPointers()
            model.bubble = .listening
        case .thinking:
            if case .explaining = model.bubble, heard == nil { return }  // keep the excerpt up
            model.bubble = .thinking(heard: heard)
        case .speaking:
            break  // set by showAnswer
        case .error(let message):
            clearPointers()
            model.bubble = .error(message)
        }
    }

    func showExplaining(_ selectedText: String) {
        clearPointers()
        model.bubble = .explaining(excerpt: selectedText)
    }

    /// About 2.5 words a second, plus a moment to look at the pointer.
    static func answerLifetime(for text: String) -> Duration {
        let words = Double(text.split(whereSeparator: \.isWhitespace).count)
        return .seconds(min(max(words / 2.5 + 3, minimumAnswerLifetime), maximumAnswerLifetime))
    }

    /// The answer so far, while it's still streaming in. No pointers or timeout yet.
    func showPartialAnswer(_ speech: String) {
        dismissTask?.cancel()
        model.bubble = .answer(speech)
    }

    /// Shows the final answer. When it's being read aloud, it stays until speech ends
    /// (`speechFinished()`), with a long safety timeout; otherwise for its reading time.
    func showAnswer(_ speech: String, pointers: [ScreenPointer], waitForSpeech: Bool) {
        setCompanionHidden(false)
        model.bubble = .answer(speech)
        model.pointers = pointers
        model.pointerGeneration += 1
        updateScreenPanels()
        scheduleDismiss(after: waitForSpeech ? .seconds(60) : Self.answerLifetime(for: speech))
    }

    /// A command was carried out: brief confirmation, then fade.
    func showDone(_ message: String) {
        clearPointers()
        model.bubble = .done(message)
        scheduleDismiss(after: .seconds(3))
    }

    /// Speech ended: leave the answer up a little longer, then fade it.
    func speechFinished() {
        guard model.bubble.isAnswer else { return }
        scheduleDismiss(after: .seconds(3))
    }

    private func scheduleDismiss(after delay: Duration) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismissAnswer()
        }
    }

    func dismissAnswer() {
        dismissTask?.cancel()
        dismissTask = nil
        let wasShowing = !model.pointers.isEmpty || model.bubble.isAnswer
        clearPointers()
        if model.bubble.isAnswer { model.bubble = .idle }
        if wasShowing { onDismiss?() }
    }

    private func clearPointers() {
        model.pointers = []
        updateScreenPanels()
    }

    private var screenPanelsVisible = false

    /// The full-screen overlay windows exist only while they draw something (a pointer
    /// or the speed trail). Kept off-screen otherwise, so no full-screen ClickBait
    /// window sits on every Space — a suspected cause of black Mission Control previews.
    private func updateScreenPanels() {
        let needed = !model.pointers.isEmpty || !model.trail.isEmpty
        guard needed != screenPanelsVisible else { return }
        screenPanelsVisible = needed
        for panel in screenPanels {
            if needed { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
    }

    // MARK: - Panels

    private static func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private func rebuildScreenPanels() {
        screenPanels.forEach { $0.close() }
        screenPanels = NSScreen.screens.map { screen in
            let panel = Self.makePanel(frame: screen.frame)
            panel.contentView = NSHostingView(rootView: ScreenOverlayView(model: model, screenFrame: screen.frame))
            panel.setFrame(screen.frame, display: false)
            return panel
        }
        screenPanelsVisible = false
        updateScreenPanels()
    }

    private func makeBubblePanel() {
        let host = NSHostingView(rootView: CompanionBubbleView(model: model))
        let panel = Self.makePanel(frame: CGRect(origin: .zero, size: OverlayModel.bubbleCanvas))
        panel.contentView = host
        model.onBubbleSizeChange = { [weak self] in
            guard let self else { return }
            moveBubble(to: anchor ?? NSEvent.mouseLocation)
        }
        panel.orderFrontRegardless()
        bubblePanel = panel
        bubbleHost = host
    }

    // MARK: - Bubble position

    /// Gap between the cursor's hotspot and the companion. The system arrow cursor
    /// extends about 12 pt right and 20 pt down from its hotspot, so this clears it.
    private static let cursorClearance = CGSize(width: 18, height: 24)

    // MARK: - Motion

    /// How long the companion takes to (mostly) catch up with the cursor. Driven by the
    /// display's refresh, not by mouse events — those arrive at different rates
    /// depending on the app under the cursor (Chrome and Electron apps differ from the
    /// desktop), which made the follow and the trail feel different from app to app.
    private static let followTime: TimeInterval = 0.06
    private var anchor: CGPoint?
    private var lastFrame: CFTimeInterval?
    private var stillFrames = 0
    private var displayLink: CADisplayLink?
    private lazy var frameTarget = FrameTarget(controller: self)
    private var visibilityTask: Task<Void, Never>?
    private var hiddenByTyping = false

    private func startMotion() {
        anchor = NSEvent.mouseLocation
        if let view = bubblePanel?.contentView {
            let link = view.displayLink(target: frameTarget, selector: #selector(FrameTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            displayLink = link
        }
        // While the mouse is still (no frames), keep checking whether something —
        // a video player, a game — has hidden the pointer.
        visibilityTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateVisibility()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        Log.app.notice("Cursor visibility: \(CursorVisibility.isAvailable ? "system-wide" : "typing only", privacy: .public)")
    }

    private func cursorMoved() {
        hiddenByTyping = false
        stillFrames = 0
        displayLink?.isPaused = false
    }

    fileprivate func frame(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let elapsed = min(max(now - (lastFrame ?? now - 1.0 / 60), 1.0 / 240), 0.1)
        lastFrame = now

        let mouse = NSEvent.mouseLocation
        let previous = anchor ?? mouse
        let pull = 1 - exp(-elapsed / Self.followTime)
        var next = CGPoint(x: previous.x + (mouse.x - previous.x) * pull, y: previous.y + (mouse.y - previous.y) * pull)
        if hypot(mouse.x - next.x, mouse.y - next.y) < 0.25 { next = mouse }
        anchor = next

        moveBubble(to: next)
        recordTrail(from: previous, to: next, elapsed: elapsed)
        updateVisibility()

        // Stop ticking once the companion has settled and the mouse is still.
        stillFrames = next == previous ? stillFrames + 1 : 0
        if stillFrames > 20 {
            link.isPaused = true
            lastFrame = nil
        }
    }

    /// Hidden whenever macOS hides the pointer (system-wide check), and — like the
    /// pointer — while typing until the mouse moves. Cards (answers, errors) stay up.
    private var lastSystemHidden = false

    private func updateVisibility() {
        let systemHidden = CursorVisibility.isVisible() == false
        if systemHidden != lastSystemHidden {
            lastSystemHidden = systemHidden
            Log.app.notice("System cursor \(systemHidden ? "hidden" : "shown", privacy: .public)")
        }
        setCompanionHidden(hiddenByTyping || systemHidden)
    }

    private func setCompanionHidden(_ hidden: Bool) {
        guard let panel = bubblePanel else { return }
        let alpha: CGFloat = hidden && model.bubble == .idle ? 0 : 1
        if panel.alphaValue != alpha { panel.alphaValue = alpha }
    }

    // MARK: - Speed trail

    /// Below this speed (points per second) there's no trail: it's for quick moves.
    private static let trailSpeedThreshold: CGFloat = 500
    /// Distance between ghosts along the path; fast moves are filled in so the trail
    /// reads as a dense stream of afterimages rather than a few scattered copies.
    private static let trailSpacing: CGFloat = 9
    private var trailIndex = 0
    private var trailCleanup: Task<Void, Never>?

    /// Where the arrowhead is drawn for a cursor position: below-right of the cursor.
    private static func arrowCenter(for mouse: CGPoint) -> CGPoint {
        CGPoint(
            x: mouse.x + cursorClearance.width + 4 + CompanionArrow.size * 0.8,
            y: mouse.y - cursorClearance.height - 4 - CompanionArrow.size * 0.8
        )
    }

    /// Ghosts along the companion's own (smoothed) path this frame.
    private func recordTrail(from start: CGPoint, to end: CGPoint, elapsed: TimeInterval) {
        guard trailEnabled(), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              model.bubble == .idle, bubblePanel?.alphaValue != 0
        else { return }
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance / elapsed >= Self.trailSpeedThreshold else { return }

        let now = Date.timeIntervalSinceReferenceDate
        let steps = max(1, Int(distance / Self.trailSpacing))
        var ghosts = model.trail.filter { now - $0.time <= OverlayModel.trailLifetime }
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            trailIndex += 1
            ghosts.append(TrailPoint(position: Self.arrowCenter(for: point), time: now - elapsed * (1 - fraction), index: trailIndex))
        }
        model.trail = Array(ghosts.suffix(OverlayModel.trailMaximum))
        updateScreenPanels()

        // Empty the trail once it has faded, so the animation clock pauses.
        trailCleanup?.cancel()
        trailCleanup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(OverlayModel.trailLifetime + 0.05))
            guard !Task.isCancelled else { return }
            self?.model.trail.removeAll()
            self?.updateScreenPanels()
        }
    }

    /// Bottom-right of the cursor, kept on the cursor's screen. The panel is a fixed
    /// canvas with the companion drawn at its top-left, so placement uses the
    /// companion's real size and the rest of the canvas can hang off-screen harmlessly.
    private func moveBubble(to mouse: NSPoint) {
        guard let panel = bubblePanel else { return }
        let content = model.bubbleSize
        let gap = Self.cursorClearance
        // Top-left corner of the companion, in AppKit coordinates (y up).
        var topLeft = NSPoint(x: mouse.x + gap.width, y: mouse.y - gap.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let bounds = screen.visibleFrame
            if topLeft.x + content.width > bounds.maxX { topLeft.x = mouse.x - gap.width - content.width }
            if topLeft.y - content.height < bounds.minY { topLeft.y = mouse.y + gap.height + content.height }
            topLeft.x = max(bounds.minX, min(topLeft.x, bounds.maxX - content.width))
            topLeft.y = min(bounds.maxY, max(topLeft.y, bounds.minY + content.height))
        }
        panel.setFrameOrigin(NSPoint(x: topLeft.x, y: topLeft.y - panel.frame.height))
    }

    // MARK: - Input

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        add(global: moves) { [weak self] _ in self?.cursorMoved() }
        add(local: moves) { [weak self] _ in self?.cursorMoved() }

        // The next click anywhere dismisses the answer (the click itself goes through).
        add(global: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismissAnswer() }

        // Escape: dismiss an answer, or cancel a question in progress. Global key
        // events need Accessibility; the local monitor covers ClickBait's own windows.
        let escape: @MainActor (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53, let self else { return }
            switch self.model.bubble {
            case .listening, .thinking, .explaining: self.onCancel?()
            default: self.dismissAnswer()
            }
        }
        add(global: .keyDown, handler: escape)
        add(local: .keyDown, handler: escape)

        let typing: @MainActor (NSEvent) -> Void = { [weak self] _ in
            self?.hiddenByTyping = true
            self?.updateVisibility()
        }
        add(global: .keyDown, handler: typing)
        add(local: .keyDown, handler: typing)
    }

    private func add(global mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { handler(event) }
        }) {
            monitors.append(monitor)
        }
    }

    private func add(local mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { handler(event) }
            return event
        }) {
            monitors.append(monitor)
        }
    }
}

private extension OverlayModel.Bubble {
    var isAnswer: Bool {
        switch self {
        case .answer, .done, .error: return true  // a click or Escape clears these
        default: return false
        }
    }
}

/// Receives display-link frames (on the main run loop) for the controller.
@MainActor
private final class FrameTarget: NSObject {
    weak var controller: OverlayController?

    init(controller: OverlayController) {
        self.controller = controller
    }

    @objc func tick(_ link: CADisplayLink) {
        controller?.frame(link)
    }
}
