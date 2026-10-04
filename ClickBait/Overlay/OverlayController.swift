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
    /// Escape: returns true if it stopped or closed something (see AppDelegate).
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
    /// At least 30 Hz: at 10 Hz the first ~100 ms of a movement after a pause looked steppy.
    private static let restingRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 30)

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
        // A long gap while the companion is moving is a stutter the user sees: log it
        // with what was going on, so it can be traced (the main thread was busy).
        if let last = lastFrame, now - last > 0.08, companionAlpha > 0, guide != nil || anchor != NSEvent.mouseLocation {
            Log.app.notice("Companion stalled \(Int((now - last) * 1000), privacy: .public) ms (\(String(describing: self.model.bubble).prefix(20), privacy: .public)\(self.guide != nil ? ", pointing" : "", privacy: .public))")
        }
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

        updateWaveform()
        defer { stepTurn(elapsed: elapsed) }
        if guide != nil {
            stepGuide(now: now, elapsed: elapsed, link: link)
            return
        }
        if isTurning || model.bubble == .listening, link.preferredFrameRateRange != Self.movingRate {
            link.preferredFrameRateRange = Self.movingRate
        }

        let previous = anchor ?? mouse
        guard previous != mouse else {
            // Settled: let the display relax its refresh rate again (unless the
            // triangle is turning or the waveform is moving).
            let busy = isTurning || model.bubble == .listening
            let wanted = busy ? Self.movingRate : Self.restingRate
            if link.preferredFrameRateRange != wanted { link.preferredFrameRateRange = wanted }
            return
        }
        if link.preferredFrameRateRange != Self.movingRate { link.preferredFrameRateRange = Self.movingRate }
        var next: CGPoint
        if let velocity = returnVelocity {
            // Coming home after pointing: the same spring as the trip out, carrying its
            // speed, instead of the follow's fast start (which looked like a snap back).
            var vx = Double(velocity.dx), vy = Double(velocity.dy)
            var x = Double(previous.x), y = Double(previous.y)
            Self.glideSpring.step(&x, velocity: &vx, toward: mouse.x, dt: elapsed)
            Self.glideSpring.step(&y, velocity: &vy, toward: mouse.y, dt: elapsed)
            next = CGPoint(x: x, y: y)
            returnVelocity = CGVector(dx: vx, dy: vy)
            if hypot(mouse.x - next.x, mouse.y - next.y) < 4 { returnVelocity = nil }  // the follow takes over
        } else {
            let pull = 1 - exp(-elapsed / Self.followTime)
            next = CGPoint(x: previous.x + (mouse.x - previous.x) * pull, y: previous.y + (mouse.y - previous.y) * pull)
            if hypot(mouse.x - next.x, mouse.y - next.y) < 0.25 { next = mouse }
        }
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

    /// Where the companion's fade is heading (the panel's own alpha lags while animating).
    private var companionAlpha: CGFloat = 1

    private func setCompanionHidden(_ hidden: Bool) {
        guard let panel = bubblePanel else { return }
        // While guiding, the triangle is the answer: it never hides.
        let alpha: CGFloat = hidden && model.bubble == .idle && guide == nil && !model.isSnipping ? 0 : 1
        guard alpha != companionAlpha else { return }
        companionAlpha = alpha
        // A quick fade rather than vanishing in one frame.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha == 0 ? 0.12 : 0.18
            panel.animator().alphaValue = alpha
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
        /// The triangle's centre, sprung toward its spot each frame.
        var center: CGPoint
        var velocity = CGVector.zero
        var targetStarted: CFTimeInterval = 0
        /// Touring the parts of a snipped thing: red, names as labels, shorter stops.
        var isTour = false
        /// A tutorial step: lavender, the instruction as the label, no timeout, and clicks
        /// don't move it on (the tutorial watches the screen for that).
        var isTutorial = false
    }

    private var guide: Guide?
    /// Gliding to a target: eases in, slows down and settles softly (about half a second).
    private static let glideSpring = Spring(period: 0.38, damping: 1)  // critically damped: no overshoot
    /// Turning: a little quicker than the glide so the tip leads.
    private static let turnSpring = Spring(period: 0.3, damping: 1)
    /// The angle the triangle is turning toward, and how fast it's turning.
    private var wantedAngle = CompanionTriangle.restingAngle
    private var angleVelocity = 0.0
    private static let dwell: CFTimeInterval = 8
    /// Long enough to read a part's name and look at it.
    private static let tourDwell: CFTimeInterval = 2.4
    /// Distance from the triangle's centre to its vertex (up to its pulse size), plus a gap.
    private static var tipDistance: CGFloat { CompanionTriangle.size * 3.squareRoot() / 4 * 1.2 + 3 }
    /// The triangle's centre measured from the companion panel's top-left corner.
    private static var triangleInset: CGFloat { 4 + 2 + CompanionTriangle.size * 0.85 }

    var isGuiding: Bool { guide != nil }

    /// Clears a green "working" pill (setup over) without touching other pills.
    func clearWorking() {
        if case .working = model.bubble { model.bubble = .idle }
    }

    /// A green "opened Notes" from a mid-tutorial switch is over: lavender again.
    func clearAction() {
        dismissTask?.cancel()
        switch model.bubble {
        case .working, .done: model.bubble = .idle
        default: break
        }
    }

    // MARK: - Tutorials (lavender)

    /// Called with every left click anywhere (global AppKit point), for tutorials.
    var onClick: ((NSPoint) -> Void)?

    func setTutoring(_ on: Bool) {
        model.isTutoring = on
        if !on {
            if guide?.isTutorial == true { endGuide() }
            if case .hint = model.bubble { model.bubble = .idle }
        }
    }

    /// Points at the current step's target, the instruction in the label. Moving
    /// between steps glides; an unchanged step just follows its target.
    func tutorialPoint(at target: ScreenPointer) {
        if case .hint = model.bubble { model.bubble = .idle }
        if var guide, guide.isTutorial {
            guard guide.targets.first != target else { return }
            let sameStep = guide.targets.first?.label == target.label
            guide.targets = [target]
            self.guide = guide
            if !sameStep { beginTarget() }
            return
        }
        guide(to: [target])
        guard var guide else { return }
        guide.isTutorial = true
        self.guide = guide
        beginTarget()
    }

    /// The walkthrough is finished: a tick by the cursor.
    func tutorialDone(_ text: String) {
        if guide?.isTutorial == true { endGuide() }
        model.bubble = .done(text)
        setCompanionHidden(false)
    }

    /// The current step's target isn't on screen: the instruction by the cursor instead.
    func tutorialHint(_ text: String) {
        if guide?.isTutorial == true { endGuide() }
        if model.bubble != .hint(text) { model.bubble = .hint(text) }
        setCompanionHidden(false)
    }

    /// The red tour of a snip's parts: the triangle visits each, its name in the label.
    func tour(_ targets: [ScreenPointer]) {
        guide(to: targets)
        guard var guide else { return }
        guide.isTour = true
        self.guide = guide
        model.isTouring = true
        beginTarget()
    }

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

    /// Better positions for the targets being shown (same order): the triangle glides
    /// on to the corrected spot, and the current target's wait starts over.
    /// Fewer targets than before means some were withdrawn (they matched nothing).
    func retarget(_ targets: [ScreenPointer]) {
        guard var guide else { return }
        guard !targets.isEmpty else {
            endGuide()
            show(.error("I couldn't find that on screen."))
            return
        }
        let current = guide.targets[guide.index]
        guide.index = min(targets.firstIndex(where: { $0.label == current.label }) ?? guide.index, targets.count - 1)
        if targets[guide.index] != current { guide.targetStarted = CACurrentMediaTime() }
        guide.targets = targets
        self.guide = guide
        beginTarget()
        Log.ask.notice("Guide: targets corrected by the close-up")
    }

    /// Back to following the cursor, gliding from wherever the triangle is now.
    func endGuide() {
        guard let guide else { return }
        // The cursor position that would put the triangle where it is: the normal follow
        // then glides it back from here.
        anchor = CGPoint(x: guide.center.x - Self.cursorClearance.width - Self.triangleInset,
                         y: guide.center.y + Self.cursorClearance.height + Self.triangleInset)
        returnVelocity = guide.velocity
        self.guide = nil
        hideGuideLabel()
        model.isGuiding = false
        model.isGuideSettled = false
        model.guideLabel = nil
        model.guideTarget = nil
        model.isTouring = false
        wantedAngle = CompanionTriangle.restingAngle  // turns back while gliding home
    }

    private func advanceGuide(reason: String) {
        guard var guide else { return }
        Log.ask.notice("Guide: moving on from target \(guide.index + 1, privacy: .public) (\(reason, privacy: .public))")
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
        model.guideLabel = guide.isTour || guide.isTutorial
            ? label  // the part's name ("probably supraspinatus")
            : GuidePhrase.next(step: guide.index, of: guide.targets.count, avoiding: model.guideLabel)
        model.guideTarget = label.isEmpty ? nil : label
        model.isGuiding = true
        showGuideLabel()
    }

    private func stepGuide(now: CFTimeInterval, elapsed: CFTimeInterval, link: CADisplayLink) {
        guard var guide else { return }
        if !guide.isTutorial, CACurrentMediaTime() - guide.targetStarted > (guide.isTour ? Self.tourDwell : Self.dwell) {
            advanceGuide(reason: "timeout")
            return
        }
        let target = guide.targets[guide.index].appKit
        let point = CGPoint(x: target.x, y: target.y)
        let spot = CGPoint(x: point.x + guide.approach.dx * Self.tipDistance, y: point.y + guide.approach.dy * Self.tipDistance)

        var next = guide.center
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            next = spot
            guide.velocity = .zero
        } else if next != spot {
            var vx = Double(guide.velocity.dx), vy = Double(guide.velocity.dy)
            var x = Double(next.x), y = Double(next.y)
            Self.glideSpring.step(&x, velocity: &vx, toward: spot.x, dt: elapsed)
            Self.glideSpring.step(&y, velocity: &vy, toward: spot.y, dt: elapsed)
            if Spring.isSettled(x, velocity: vx, target: spot.x, tolerance: 0.2),
               Spring.isSettled(y, velocity: vy, target: spot.y, tolerance: 0.2) {
                (x, y, vx, vy) = (spot.x, spot.y, 0, 0)
            }
            next = CGPoint(x: x, y: y)
            guide.velocity = CGVector(dx: vx, dy: vy)
        }
        let moving = next != guide.center
        guide.center = next
        self.guide = guide
        if model.isGuideSettled == moving { model.isGuideSettled = !moving }  // pulse once arrived

        let wanted: CAFrameRateRange = moving || isTurning ? Self.movingRate : Self.restingRate
        if link.preferredFrameRateRange != wanted { link.preferredFrameRateRange = wanted }

        // Point the vertex at the target (0° = up, clockwise; AppKit's y points up).
        // One heading per stop — from where the triangle will rest toward the target —
        // so it turns once and holds still (aiming from its moving position made the tip
        // wobble as it arrived).
        wantedAngle = atan2(-guide.approach.dx, -guide.approach.dy) * 180 / .pi

        bubblePanel?.setFrameOrigin(NSPoint(x: next.x - Self.triangleInset,
                                            y: next.y + Self.triangleInset - (bubblePanel?.frame.height ?? 0)))
        placeGuideLabel(triangleCenter: next, awayFrom: guide.approach, elapsed: elapsed)
    }

    /// Whether the triangle is still turning toward `wantedAngle`.
    private var isTurning: Bool {
        abs(angleDelta) > 0.2 || abs(angleVelocity) > 2
    }

    /// `wantedAngle` relative to the current angle, the short way round.
    private var angleDelta: Double {
        var delta = (wantedAngle - model.triangleAngle).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    /// Turns the triangle with a spring, in the frame loop rather than a SwiftUI
    /// animation (which restarted every frame while gliding and stuttered).
    private func stepTurn(elapsed: CFTimeInterval) {
        guard isTurning else { return }
        let target = model.triangleAngle + angleDelta
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            model.triangleAngle = target
            angleVelocity = 0
            return
        }
        var angle = model.triangleAngle
        Self.turnSpring.step(&angle, velocity: &angleVelocity, toward: target, dt: elapsed)
        if Spring.isSettled(angle, velocity: angleVelocity, target: target, tolerance: 0.2) {
            angle = target
            angleVelocity = 0
        }
        model.triangleAngle = angle
    }

    // MARK: - Listening waveform

    /// The microphone's current level (RMS, 0…1) while listening.
    var levelSource: (() -> Float)?
    private var waveEnvelope: Double = 0

    /// Follows the voice: rises at once, falls back over ~150 ms, on a dB scale so
    /// quiet and loud speech both move the bars.
    private func updateWaveform() {
        guard model.bubble == .listening else {
            if model.waveLevel != 0 { model.waveLevel = 0 }
            waveEnvelope = 0
            return
        }
        let rms = Double(levelSource?() ?? 0)
        let decibels = 20 * log10(max(rms, 0.000_01))
        let loudness = min(max((decibels + 55) / 40, 0), 1)  // −55 dB → 0, −15 dB → 1
        waveEnvelope = loudness > waveEnvelope ? loudness : waveEnvelope * 0.88 + loudness * 0.12
        if abs(model.waveLevel - waveEnvelope) > 0.005 { model.waveLevel = waveEnvelope }
    }

    /// Beside the triangle on the side away from the target (left of it when the target
    /// is to the left), so the label never covers what it's pointing at.
    private func placeGuideLabel(triangleCenter c: CGPoint, awayFrom approach: CGVector, elapsed: CFTimeInterval) {
        guard let panel = guideLabelPanel else { return }
        let size = model.guideLabelSize
        // Away from the target, and always fully inside the screen's visible area (below
        // the menu bar, above the Dock): the other side, or pushed in, when it won't fit.
        // The view pads the pill by 6 pt for its shadow; that padding may overhang.
        let screen = NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let spot = PillPlacement.beside(
            Point(x: c.x, y: c.y), width: size.width - 12, height: size.height - 12, gap: 12, preferRight: approach.dx >= 0,
            bounds: Rect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height))
        let target = CGPoint(x: spot.x - 6, y: spot.top + 6 - panel.frame.height)
        // The label rides with the triangle; when the next stop puts it on the other
        // side it glides across instead of jumping.
        var origin = labelOrigin ?? target
        var vx = Double(labelVelocity.dx), vy = Double(labelVelocity.dy)
        var ox = Double(origin.x), oy = Double(origin.y)
        Self.labelSpring.step(&ox, velocity: &vx, toward: target.x, dt: elapsed)
        Self.labelSpring.step(&oy, velocity: &vy, toward: target.y, dt: elapsed)
        origin = CGPoint(x: ox, y: oy)
        labelOrigin = origin
        labelVelocity = CGVector(dx: vx, dy: vy)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    private static let labelSpring = Spring(period: 0.22, damping: 1)
    private var labelOrigin: CGPoint?
    private var labelVelocity = CGVector.zero
    /// Set while the triangle comes home after pointing (see the follow in `frame`).
    private var returnVelocity: CGVector?

    private func showGuideLabel() {
        guard let panel = guideLabelPanel, !panel.isVisible || panel.alphaValue < 1 else { return }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func hideGuideLabel() {
        guard let panel = guideLabelPanel, panel.isVisible else { return }
        labelOrigin = nil
        labelVelocity = .zero
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new guide may have started meanwhile: only hide if still unused.
                if self?.guide == nil { panel.orderOut(nil) }
            }
        })
    }

    // MARK: - Input

    private func installMonitors() {
        // The next click anywhere dismisses the answer (the click itself goes through).
        add(global: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown { onClick?(NSEvent.mouseLocation) }
            if guide?.isTutorial == true { return }  // the tutorial decides what a click means
            if guide != nil { advanceGuide(reason: "click") } else { dismissAnswer() }
        }

        // Escape in ClickBait's own windows (typing in the chat). Esc in other apps is
        // handled by InputInterceptor, which takes it only while ClickBait is busy.
        add(local: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return }
            if self.onEscape?() != true { self.dismissAnswer() }
        }

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

/// What the triangle says while it points: tiny and friendly, lowercase words and
/// punctuation only — never the element's name or step numbers.
enum GuidePhrase {
    static let single = ["found it!", "this one!", "over here!", "right here!"]
    static let first = ["first, this one!", "first, over here!", "start here!"]
    static let middle = ["then this one!", "next, over here!", "then right here!"]
    static let last = ["and finally, this one!", "and then here!", "last one, right here!"]

    static func next(step: Int, of count: Int, avoiding previous: String?) -> String {
        let pool = count <= 1 ? single : step == 0 ? first : step == count - 1 ? last : middle
        return pool.filter { $0 != previous }.randomElement() ?? pool[0]
    }
}
