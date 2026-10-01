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
        resizeBubble()
    }

    func showExplaining(_ selectedText: String) {
        clearPointers()
        model.bubble = .explaining(excerpt: selectedText)
        resizeBubble()
    }

    /// About 2.5 words a second, plus a moment to look at the pointer.
    static func answerLifetime(for text: String) -> Duration {
        let words = Double(text.split(whereSeparator: \.isWhitespace).count)
        return .seconds(min(max(words / 2.5 + 3, minimumAnswerLifetime), maximumAnswerLifetime))
    }

    func showAnswer(_ speech: String, pointers: [ScreenPointer]) {
        model.bubble = .answer(speech)
        model.pointers = pointers
        model.pointerGeneration += 1
        screenPanels.forEach { $0.orderFrontRegardless() }
        resizeBubble()

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.answerLifetime(for: speech))
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
        resizeBubble()
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
        let panel = Self.makePanel(frame: CGRect(origin: .zero, size: host.fittingSize))
        panel.contentView = host
        panel.orderFrontRegardless()
        bubblePanel = panel
        bubbleHost = host
    }

    // MARK: - Bubble position

    /// Gap between the cursor's hotspot and the companion. The system arrow cursor
    /// extends about 12 pt right and 20 pt down from its hotspot, so this clears it.
    private static let cursorClearance = CGSize(width: 18, height: 24)

    /// Bottom-right of the cursor, kept on the cursor's screen.
    private func moveBubble(to mouse: NSPoint) {
        guard let panel = bubblePanel else { return }
        let size = panel.frame.size
        let gap = Self.cursorClearance
        var origin = NSPoint(x: mouse.x + gap.width, y: mouse.y - gap.height - size.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let bounds = screen.visibleFrame
            if origin.x + size.width > bounds.maxX { origin.x = mouse.x - gap.width - size.width }
            if origin.y < bounds.minY { origin.y = mouse.y + gap.height }
            origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
            origin.y = max(bounds.minY, min(origin.y, bounds.maxY - size.height))
        }
        panel.setFrameOrigin(origin)
    }

    private var pendingShrink: Task<Void, Never>?

    /// Grows the panel right away; shrinks it only after the morph back to the
    /// arrowhead has played, so the animation isn't clipped. `moveBubble` keeps the
    /// panel's top-left (where the arrowhead sits) fixed relative to the cursor.
    private func resizeBubble() {
        pendingShrink?.cancel()
        // Let SwiftUI lay out the new content before measuring it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = bubblePanel, let host = bubbleHost else { return }
            host.layoutSubtreeIfNeeded()
            let target = host.fittingSize
            if target.width < panel.frame.width || target.height < panel.frame.height {
                pendingShrink = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    self?.applyBubbleSize()
                }
            } else {
                applyBubbleSize()
            }
        }
    }

    private func applyBubbleSize() {
        guard let panel = bubblePanel, let host = bubbleHost else { return }
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
        moveBubble(to: NSEvent.mouseLocation)
        panel.orderFrontRegardless()
    }

    // MARK: - Input

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        add(global: moves) { [weak self] _ in self?.moveBubble(to: NSEvent.mouseLocation) }
        add(local: moves) { [weak self] _ in self?.moveBubble(to: NSEvent.mouseLocation) }

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
        if case .answer = self { return true }
        return false
    }
}
