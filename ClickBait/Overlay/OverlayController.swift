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

    /// The full-screen overlay windows exist only while they draw a pointer. Kept off-screen otherwise, so no full-screen ClickBait
    /// window sits on every Space — a suspected cause of black Mission Control previews.
    private func updateScreenPanels() {
        let needed = !model.pointers.isEmpty
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

    /// How long the companion takes to (mostly) catch up with the cursor.
    ///
    /// Motion is driven entirely by the display's refresh: every frame reads the cursor
    /// position. Mouse-moved events can't be used even to wake this up — macOS only
    /// generates them for apps that ask, so over Chrome or Electron apps (Claude) they
    /// arrive late or in bursts, which made the follow feel different from the desktop.
    private static let followTime: TimeInterval = 0.06
    /// The system-wide cursor check is a call into the window server; ~20 times a second
    /// is plenty to catch a video hiding the pointer.
    private static let visibilityInterval: CFTimeInterval = 0.05
    private var anchor: CGPoint?
    private var lastMouse: CGPoint?
    private var lastFrame: CFTimeInterval?
    private var lastVisibilityCheck: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private lazy var frameTarget = FrameTarget(controller: self)
    private var hiddenByTyping = false

    private func startMotion() {
        anchor = NSEvent.mouseLocation
        if let view = bubblePanel?.contentView {
            let link = view.displayLink(target: frameTarget, selector: #selector(FrameTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        Log.app.notice("Cursor visibility: \(CursorVisibility.isAvailable ? "system-wide" : "typing only", privacy: .public)")
    }

    fileprivate func frame(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let elapsed = min(max(now - (lastFrame ?? now - 1.0 / 60), 1.0 / 240), 0.1)
        lastFrame = now

        let mouse = NSEvent.mouseLocation
        if mouse != lastMouse {
            if lastMouse != nil { hiddenByTyping = false }  // like the pointer: moving shows it again
            lastMouse = mouse
        }
        if now - lastVisibilityCheck >= Self.visibilityInterval {
            lastVisibilityCheck = now
            updateVisibility()
        }

        let previous = anchor ?? mouse
        guard previous != mouse else { return }  // settled: nothing to do this frame
        let pull = 1 - exp(-elapsed / Self.followTime)
        var next = CGPoint(x: previous.x + (mouse.x - previous.x) * pull, y: previous.y + (mouse.y - previous.y) * pull)
        if hypot(mouse.x - next.x, mouse.y - next.y) < 0.25 { next = mouse }
        anchor = next
        moveBubble(to: next)
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
