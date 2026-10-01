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
        screenPanels.forEach { $0.orderFrontRegardless() }
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
            panel.orderFrontRegardless()
            return panel
        }
    }

    private func makeBubblePanel() {
        let host = NSHostingView(rootView: CompanionBubbleView(model: model))
        let panel = Self.makePanel(frame: CGRect(origin: .zero, size: OverlayModel.bubbleCanvas))
        panel.contentView = host
        model.onBubbleSizeChange = { [weak self] in self?.moveBubble(to: NSEvent.mouseLocation) }
        panel.orderFrontRegardless()
        bubblePanel = panel
        bubbleHost = host
    }

    // MARK: - Bubble position

    /// Gap between the cursor's hotspot and the companion. The system arrow cursor
    /// extends about 12 pt right and 20 pt down from its hotspot, so this clears it.
    private static let cursorClearance = CGSize(width: 18, height: 24)

    // MARK: - Speed trail

    /// Below this speed (points per second) there's no trail: it's for quick moves.
    private static let trailSpeedThreshold: CGFloat = 500
    /// Distance between ghosts along the path; fast flicks are filled in so the trail
    /// reads as a dense stream of afterimages rather than a few scattered copies.
    private static let trailSpacing: CGFloat = 9
    private var lastMouse: (point: CGPoint, time: TimeInterval)?
    private var trailIndex = 0
    private var trailCleanup: Task<Void, Never>?

    private func cursorMoved() {
        let mouse = NSEvent.mouseLocation
        setCompanionHidden(false)
        moveBubble(to: mouse)
        recordTrail(at: mouse)
    }

    /// macOS hides the pointer while you type and shows it again when the mouse moves;
    /// the idle companion does the same. Cards (answers, errors) stay visible.
    private func setCompanionHidden(_ hidden: Bool) {
        guard let panel = bubblePanel else { return }
        let alpha: CGFloat = hidden && model.bubble == .idle ? 0 : 1
        if panel.alphaValue != alpha { panel.alphaValue = alpha }
    }

    /// Where the arrowhead is drawn for a cursor position: below-right of the cursor.
    private static func arrowCenter(for mouse: CGPoint) -> CGPoint {
        CGPoint(
            x: mouse.x + cursorClearance.width + 4 + CompanionArrow.size * 0.8,
            y: mouse.y - cursorClearance.height - 4 - CompanionArrow.size * 0.8
        )
    }

    private func recordTrail(at mouse: CGPoint) {
        let now = Date.timeIntervalSinceReferenceDate
        defer { lastMouse = (mouse, now) }
        guard trailEnabled(), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              model.bubble == .idle, let last = lastMouse
        else { return }
        let elapsed = now - last.time
        let distance = hypot(mouse.x - last.point.x, mouse.y - last.point.y)
        guard elapsed > 0, distance / elapsed >= Self.trailSpeedThreshold else { return }

        // Ghosts every `trailSpacing` points from the last move to this one, with times
        // spread across the interval so older ones fade first.
        let steps = max(1, Int(distance / Self.trailSpacing))
        var ghosts = model.trail.filter { now - $0.time <= OverlayModel.trailLifetime }
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            let point = CGPoint(x: last.point.x + (mouse.x - last.point.x) * fraction,
                                y: last.point.y + (mouse.y - last.point.y) * fraction)
            trailIndex += 1
            ghosts.append(TrailPoint(position: Self.arrowCenter(for: point), time: last.time + elapsed * fraction, index: trailIndex))
        }
        model.trail = Array(ghosts.suffix(OverlayModel.trailMaximum))

        // Empty the trail once it has faded, so the animation clock pauses.
        trailCleanup?.cancel()
        trailCleanup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(OverlayModel.trailLifetime + 0.05))
            guard !Task.isCancelled else { return }
            self?.model.trail.removeAll()
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

        let typing: @MainActor (NSEvent) -> Void = { [weak self] _ in self?.setCompanionHidden(true) }
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
