import AppKit
import ClickBaitCore
import SwiftUI

/// Owns the companion: the triangle that follows the cursor, shows ClickBait's state,
/// and — after an answer — detaches to glide over and point at targets on screen.
/// Click-through everywhere; never takes focus.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    /// Called when the user dismisses an answer (click, Escape, or timeout).
    var onDismiss: (() -> Void)?
    /// Called when Escape is pressed while ClickBait is listening or thinking.
    var onCancel: (() -> Void)?
    /// Escape otherwise: returns true if it closed something (the chat bubble).
    var onEscape: (() -> Bool)?

    private var guideLabelPanel: NSPanel?
    private var bubblePanel: NSPanel?
    private var bubbleHost: NSHostingView<CompanionBubbleView>?
    private var monitors: [Any] = []
    private var dismissTask: Task<Void, Never>?

    func start() {
        makeBubblePanel()
        installMonitors()
        startMotion()
        moveBubble(to: NSEvent.mouseLocation)
    }

    // MARK: - State

    func show(_ state: AskState, heard: String? = nil) {
        switch state {
        case .idle:
            model.bubble = .idle
        case .listening:
            setCompanionHidden(false)
            dismissTask?.cancel()
            endGuide()
            model.bubble = .listening
        case .thinking:
            if case .explaining = model.bubble, heard == nil { return }  // keep the excerpt up
            model.bubble = .thinking(heard: heard)
        case .speaking:
            break  // set by showAnswer
        case .error(let message):
            endGuide()
            model.bubble = .error(message)
        }
    }

    func showExplaining(_ selectedText: String) {
        endGuide()
        model.bubble = .explaining(excerpt: selectedText)
    }

    /// Where a chat bubble should open: where the companion's card sits now.
    var companionTopLeft: CGPoint {
        let mouse = anchor ?? NSEvent.mouseLocation
        return CGPoint(x: mouse.x + Self.cursorClearance.width + 4, y: mouse.y - Self.cursorClearance.height - 4)
    }

    /// A command is running (green, pulsing) — file actions can take a while.
    func showWorking(_ message: String) {
        endGuide()
        dismissTask?.cancel()
        setCompanionHidden(false)
        model.bubble = .working(message)
    }

    /// A command was carried out: brief confirmation, then fade.
    func showDone(_ message: String) {
        model.bubble = .done(message)
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
        let wasShowing = model.bubble.isAnswer
        if model.bubble.isAnswer { model.bubble = .idle }
        if wasShowing { onDismiss?() }
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

    private func makeBubblePanel() {
        let host = NSHostingView(rootView: CompanionBubbleView(model: model))
        let panel = Self.makePanel(frame: CGRect(origin: .zero, size: OverlayModel.bubbleCanvas))
        panel.contentView = host
        model.onBubbleSizeChange = { [weak self] in
            guard let self, guide == nil else { return }
            moveBubble(to: anchor ?? NSEvent.mouseLocation)
        }
        panel.orderFrontRegardless()
        bubblePanel = panel
        bubbleHost = host

        let label = Self.makePanel(frame: CGRect(origin: .zero, size: OverlayModel.guideLabelCanvas))
        label.contentView = NSHostingView(rootView: GuideLabelView(model: model))
        guideLabelPanel = label
    }

    // MARK: - Bubble position

    /// Gap between the cursor's hotspot and the companion. The system arrow cursor
    /// extends about 12 pt right and 20 pt down from its hotspot, so this clears it.
    private static let cursorClearance = CGSize(width: 18, height: 24)

    // MARK: - Motion

    /// How long the companion takes to (mostly) catch up with the cursor: a soft, floaty
    /// glide (the feel the desktop used to have by accident, now on purpose everywhere).
    ///
    /// Motion is driven entirely by the display's refresh: every frame reads the cursor
    /// position. Mouse-moved events can't be used even to wake this up — macOS only
    /// generates them for apps that ask, so over Chrome or Electron apps (Claude) they
    /// arrive late or in bursts, which made the follow feel different from the desktop.
    /// The display's refresh rate also varies (ProMotion drops it over static content
    /// like the desktop), so a steady rate is requested while the companion moves.
    private static let followTime: TimeInterval = 0.11
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
    /// Steady frames while moving, so the glide looks the same over any content.
    private static let movingRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    /// Low rate while still: the cursor is still sampled (to notice movement and hidden
    /// pointers) without keeping a ProMotion display at 120 Hz.
    private static let restingRate = CAFrameRateRange(minimum: 10, maximum: 60, preferred: 30)

    private func startMotion() {
        anchor = NSEvent.mouseLocation
        if let view = bubblePanel?.contentView {
            let link = view.displayLink(target: frameTarget, selector: #selector(FrameTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            link.preferredFrameRateRange = Self.restingRate
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

        if guide != nil {
            stepGuide(now: now, elapsed: elapsed, link: link)
            return
        }

        let previous = anchor ?? mouse
        guard previous != mouse else {
            // Settled: let the display relax its refresh rate again.
            if link.preferredFrameRateRange != Self.restingRate { link.preferredFrameRateRange = Self.restingRate }
            return
        }
        if link.preferredFrameRateRange != Self.movingRate { link.preferredFrameRateRange = Self.movingRate }
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
        // While guiding, the triangle is the answer: it never hides.
        let alpha: CGFloat = hidden && model.bubble == .idle && guide == nil && !model.isSnipping ? 0 : 1
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

    /// Strawberry Red while the user marks part of the screen (hold ⌥⌘).
    func setSnipping(_ snipping: Bool) {
        if snipping { endGuide() }
        model.isSnipping = snipping
        setCompanionHidden(false)
    }

    // MARK: - Guiding (roadmap phase B)

    /// After an answer the triangle detaches from the cursor, glides to each target in
    /// turn and points its vertex at it, then glides back. A click anywhere moves on
    /// (the user has probably just clicked the target); so does `dwell` without one.
    private struct Guide {
        var targets: [ScreenPointer]
        var index = 0
        /// Unit vector from the target toward where the triangle sits.
        var approach = CGVector(dx: -0.7071, dy: 0.7071)
        /// The triangle's centre, eased toward its spot each frame.
        var center: CGPoint
        var targetStarted: CFTimeInterval = 0
    }

    private var guide: Guide?
    private static let guideGlideTime: TimeInterval = 0.16
    private static let dwell: CFTimeInterval = 8
    /// Distance from the triangle's centre to its vertex (up to its pulse size), plus a gap.
    private static var tipDistance: CGFloat { CompanionTriangle.size * 3.squareRoot() / 4 * 1.2 + 3 }
    /// The triangle's centre measured from the companion panel's top-left corner.
    private static var triangleInset: CGFloat { 4 + 2 + CompanionTriangle.size * 0.85 }

    var isGuiding: Bool { guide != nil }

    func guide(to targets: [ScreenPointer]) {
        endGuide()
        guard !targets.isEmpty else { return }
        // Start from wherever the triangle is drawn now.
        let frame = bubblePanel?.frame ?? .zero
        let start = CGPoint(x: frame.minX + Self.triangleInset, y: frame.maxY - Self.triangleInset)
        guide = Guide(targets: targets, center: start)
        model.bubble = .idle
        beginTarget()
        setCompanionHidden(false)
        Log.ask.notice("Guiding to \(targets.count, privacy: .public) target(s)")
    }

    /// Back to following the cursor, gliding from wherever the triangle is now.
    func endGuide() {
        guard let guide else { return }
        // The cursor position that would put the triangle where it is: the normal follow
        // then glides it back from here.
        anchor = CGPoint(x: guide.center.x - Self.cursorClearance.width - Self.triangleInset,
                         y: guide.center.y + Self.cursorClearance.height + Self.triangleInset)
        self.guide = nil
        guideLabelPanel?.orderOut(nil)
        model.isGuiding = false
        model.guideLabel = nil
        model.triangleAngle = CompanionTriangle.restingAngle
    }

    private func advanceGuide() {
        guard var guide else { return }
        if guide.index + 1 < guide.targets.count {
            guide.index += 1
            self.guide = guide
            beginTarget()
        } else {
            endGuide()
        }
    }

    private func beginTarget() {
        guard var guide else { return }
        let target = guide.targets[guide.index].appKit
        let point = CGPoint(x: target.x, y: target.y)
        // Approach from the side the triangle is already on, staying on screen.
        var direction = CGVector(dx: guide.center.x - point.x, dy: guide.center.y - point.y)
        let length = hypot(direction.dx, direction.dy)
        direction = length > 1 ? CGVector(dx: direction.dx / length, dy: direction.dy / length) : CGVector(dx: -0.7071, dy: 0.7071)
        let spot = CGPoint(x: point.x + direction.dx * 40, y: point.y + direction.dy * 40)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
           !screen.visibleFrame.insetBy(dx: 10, dy: 10).contains(spot) {
            direction = CGVector(dx: -direction.dx, dy: -direction.dy)
        }
        guide.approach = direction
        guide.targetStarted = CACurrentMediaTime()
        self.guide = guide

        let label = guide.targets[guide.index].label
        let step = guide.targets.count > 1 ? "\(guide.index + 1)/\(guide.targets.count)" : nil
        model.guideLabel = [step, label.isEmpty ? nil : label].compactMap { $0 }.joined(separator: " · ")
        model.isGuiding = true
        guideLabelPanel?.orderFrontRegardless()
    }

    private func stepGuide(now: CFTimeInterval, elapsed: CFTimeInterval, link: CADisplayLink) {
        guard var guide else { return }
        if CACurrentMediaTime() - guide.targetStarted > Self.dwell {
            advanceGuide()
            return
        }
        let target = guide.targets[guide.index].appKit
        let point = CGPoint(x: target.x, y: target.y)
        let spot = CGPoint(x: point.x + guide.approach.dx * Self.tipDistance, y: point.y + guide.approach.dy * Self.tipDistance)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let pull = reduceMotion ? 1 : 1 - exp(-elapsed / Self.guideGlideTime)
        var next = CGPoint(x: guide.center.x + (spot.x - guide.center.x) * pull, y: guide.center.y + (spot.y - guide.center.y) * pull)
        if hypot(spot.x - next.x, spot.y - next.y) < 0.25 { next = spot }
        let moving = next != guide.center
        guide.center = next
        self.guide = guide

        let wanted: CAFrameRateRange = moving ? Self.movingRate : Self.restingRate
        if link.preferredFrameRateRange != wanted { link.preferredFrameRateRange = wanted }

        // Point the vertex at the target (0° = up, clockwise; AppKit's y points up).
        var angle = atan2(point.x - next.x, point.y - next.y) * 180 / .pi
        while angle - model.triangleAngle > 180 { angle -= 360 }  // turn the short way round
        while angle - model.triangleAngle < -180 { angle += 360 }
        if abs(angle - model.triangleAngle) > 0.5 { model.triangleAngle = angle }

        bubblePanel?.setFrameOrigin(NSPoint(x: next.x - Self.triangleInset,
                                            y: next.y + Self.triangleInset - (bubblePanel?.frame.height ?? 0)))
        placeGuideLabel(triangleCenter: next, awayFrom: guide.approach)
    }

    /// Beside the triangle on the side away from the target (left of it when the target
    /// is to the left), so the label never covers what it's pointing at.
    private func placeGuideLabel(triangleCenter c: CGPoint, awayFrom approach: CGVector) {
        guard let panel = guideLabelPanel else { return }
        let size = model.guideLabelSize
        let gap: CGFloat = 12
        let x = approach.dx >= 0 ? c.x + gap - 6 : c.x - gap - size.width + 6  // 6 = the view's shadow padding
        let top = c.y + size.height / 2
        let origin = NSPoint(x: x, y: top - panel.frame.height)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    // MARK: - Input

    private func installMonitors() {
        // The next click anywhere dismisses the answer (the click itself goes through).
        add(global: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if guide != nil { advanceGuide() } else { dismissAnswer() }
        }

        // Escape: dismiss an answer, or cancel a question in progress. Global key
        // events need Accessibility; the local monitor covers ClickBait's own windows.
        let escape: @MainActor (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53, let self else { return }
            switch self.model.bubble {
            case .listening, .thinking, .explaining: self.onCancel?()
            default:
                if self.guide != nil { self.endGuide() }
                if self.onEscape?() != true { self.dismissAnswer() }
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
