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
    /// The triangle sets off for a target (a guide, tour or walkthrough step).
    var onGuide: (() -> Void)?

    private var guideLabelStage: StagePanel?
    private var bubbleStage: StagePanel?
    private var guideLabelPanel: NSPanel? { guideLabelStage?.panel }
    private var bubblePanel: NSPanel? { bubbleStage?.panel }
    private var bubbleHost: NSHostingView<CompanionBubbleView>?
    private var monitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?
    private var dismissTask: Task<Void, Never>?
    private var peelFlightStages: [UUID: StagePanel] = [:]

    func start() {
        makeBubblePanel()
        followSpaces()
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

    /// The centre of the companion's triangle at rest beside the cursor (global AppKit),
    /// using the same placement as the companion itself, edge flips included. The chat's
    /// logo opens exactly here.
    var companionTriangleCenter: CGPoint {
        // Where it's actually drawn now (it trails the cursor and moves aside for pills),
        // read from its window — not where it would rest next to the mouse.
        if guide == nil, let frame = bubbleStage?.contentFrame, frame.width > 0 {
            return CGPoint(x: frame.minX + Self.triangleInset, y: frame.maxY - Self.triangleInset)
        }
        let topLeft = restingTopLeft(for: NSEvent.mouseLocation)
        return CGPoint(x: topLeft.x + Self.triangleInContent, y: topLeft.y - Self.triangleInContent)
    }

    /// The peel, after HeyClicky's spawn (`AgentDock.spawn`): a copy of the companion in the
    /// job's colour grows at the cursor (0.1 s), then flies the arc into its tile (0.55 s),
    /// shrinking and turning upright as it lands, while the real companion pops back in at
    /// the cursor (Azure, listening) as the copy sets off. All of it is Core Animation
    /// keyframes sampled from `AgentDock.spawn`: nothing in SwiftUI changes per frame.
    /// Reduce Motion, or a tile on another display: no flight (the tile fades in).
    func peel(to target: CGPoint?, tone: CompanionTone, completion: @escaping @MainActor () -> Void) {
        let start = companionTriangleCenter
        // The safe fallback (`AgentDock.PeelMotion.inPlace`): the companion pops straight back,
        // the tile fades in on its own; the job is unaffected.
        let popInPlace = { [model] in
            model.companionPopDelay = AgentDock.freshCompanionDelay(.inPlace)
            model.companionPop &+= 1
            completion()
        }
        let sameDisplay = target.map { target in
            let source = NSScreen.screens.first(where: { $0.frame.contains(start) })
            return source != nil && source?.frame == NSScreen.screens.first(where: { $0.frame.contains(target) })?.frame
        } ?? false
        let motion = AgentDock.peelMotion(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                          hasSlot: target != nil, sameDisplay: sameDisplay)
        guard motion == .flight, let target else {
            Log.app.notice("Peel shown in place (no flight)")
            popInPlace()
            return
        }

        // Room for the triangle at 2× with its glow and the swell.
        let size = CGSize(width: 96, height: 96)
        let host = NSHostingView(rootView: CompanionTriangle(tone: tone, pulsing: false, angle: 0)
            .frame(width: size.width, height: size.height))
        host.wantsLayer = true
        let stage = StagePanel(content: host, size: size, makePanel: Self.makePanel)
        stage.setOrigin(CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2), anchor: start)
        guard let stageLayer = host.superview?.layer, let contentLayer = host.layer else {
            // Nothing to animate: don't leave the unused stage behind.
            stage.panel.close()
            Log.app.notice("Peel shown in place: no layer to animate")
            popInPlace()
            return
        }
        model.companionPopDelay = AgentDock.freshCompanionDelay(.flight)
        model.companionPop &+= 1
        // Scale and turn about the triangle's centre (AppKit layers default to a corner).
        contentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentLayer.position = CGPoint(x: host.frame.midX, y: host.frame.midY)

        let flightID = UUID()
        peelFlightStages[flightID] = stage
        let initial = stageLayer.sublayerTransform
        let duration = AgentDock.growTime + AgentDock.flightTime
        let samples = 40
        let times = (0...samples).map { Double($0) / Double(samples) }
        let frames = times.map {
            AgentDock.spawn(at: $0 * duration, from: Point(x: start.x, y: start.y), to: Point(x: target.x, y: target.y))
        }
        let travel = CAKeyframeAnimation(keyPath: "sublayerTransform")
        travel.values = frames.map { frame in
            NSValue(caTransform3D: CATransform3DTranslate(initial, frame.center.x - start.x, frame.center.y - start.y, 0))
        }
        // The triangle's angle is clockwise; a layer's rotation turns it anticlockwise
        // on screen (checked by rendering the layer tree, 2026-10-11).
        let shape = CAKeyframeAnimation(keyPath: "transform")
        shape.values = frames.map { frame in
            NSValue(caTransform3D: CATransform3DRotate(CATransform3DMakeScale(frame.scale, frame.scale, 1),
                                                       -frame.angle * .pi / 180, 0, 0, 1))
        }
        // Gone into its tile on the last frames, where the tile's own triangle sits.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: AgentDock.copyFadeStart), 1]
        for animation in [travel, shape, fade] {
            animation.duration = duration
            animation.calculationMode = .linear
        }
        travel.keyTimes = times.map { NSNumber(value: $0) }
        shape.keyTimes = travel.keyTimes

        let last = frames[frames.count - 1]
        stageLayer.sublayerTransform = CATransform3DTranslate(initial, last.center.x - start.x, last.center.y - start.y, 0)
        contentLayer.transform = CATransform3DMakeScale(last.scale, last.scale, 1)
        contentLayer.opacity = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak panel = stage.panel] in
            panel?.orderOut(nil)
            panel?.close()
            self?.peelFlightStages.removeValue(forKey: flightID)
            completion()
        }
        stageLayer.add(travel, forKey: "peel-travel")
        contentLayer.add(shape, forKey: "peel-shape")
        contentLayer.add(fade, forKey: "peel-fade")
        CATransaction.commit()
        stage.panel.orderFrontRegardless()
    }

    /// Where a confirmation should open: where the companion's card sits now.
    var companionTopLeft: CGPoint {
        let mouse = anchor ?? NSEvent.mouseLocation
        return CGPoint(x: mouse.x + Self.cursorClearance.width + 4, y: mouse.y - Self.cursorClearance.height - 4)
    }

    /// Lavender: a walkthrough is being planned or run.
    var isTutoring: Bool { model.isTutoring }

    /// A pill is up (a result, a problem, an answer): not to be replaced by a repeat.
    var isShowingWords: Bool { model.bubble.hasWords }

    /// Takes down a short-answer pill without counting it as dismissing an answer.
    func clearShortAnswer() {
        guard case .answer = model.bubble else { return }
        stickyNote = false
        dismissTask?.cancel()
        model.bubble = .idle
    }

    /// A reply short enough for a pill ("Yep, it's on!"): said by the companion, no chat.
    func showShortAnswer(_ text: String) {
        endGuide()
        setCompanionHidden(false)
        stickyNote = false
        model.bubble = .answer(text)
        scheduleDismiss(after: .seconds(5))
    }

    /// "answer's ready in Safari": stays its full `time` even if the user clicks in other
    /// apps meanwhile (a click took it away at once, 2026-10-12, so the answer seemed lost).
    /// Esc, a new question or going back to that app still clear it.
    func showReadyNote(_ text: String, for time: Duration) {
        endGuide()
        setCompanionHidden(false)
        model.bubble = .answer(text)
        stickyNote = true
        scheduleDismiss(after: time)
    }

    /// The pill up is a ready note: a click elsewhere doesn't dismiss it.
    private var stickyNote = false

    /// A background ClickBait finished: its summary by the companion, in the job's colour,
    /// for 5 s. Only when nothing else is saying anything (the caller waits for that).
    /// `force`: also over a question's own thinking words (a press that found nothing to send away).
    func showJobResult(_ text: String, tone: CompanionTone, force: Bool = false) {
        guard force || (!model.bubble.hasWords && !isGuiding) else { return }
        setCompanionHidden(false)
        model.bubble = .jobResult(text, tone)
        scheduleDismiss(after: .seconds(5))
    }

    /// fn+⌃ dictation: Shamrock bars that follow the voice while held (`listening`), the
    /// Shamrock spin while the words are written (`!listening`), then back to idle.
    func setDictating(_ on: Bool, listening: Bool = true) {
        model.isDictating = on
        guard on else {
            switch model.bubble {
            case .listening, .thinking: model.bubble = .idle
            default: break
            }
            return
        }
        endGuide()
        dismissTask?.cancel()
        setCompanionHidden(false)
        model.bubble = listening ? .listening : .thinking(heard: nil)
    }

    /// A hello on coming back: typed out, held briefly, gone (`Greeting.timing`). Only when
    /// the companion has nothing else to say; false when it was busy.
    @discardableResult
    func showGreeting(_ text: String) -> Bool {
        guard model.bubble == .idle, !isGuiding, !model.isSnipping, !model.isTutoring else { return false }
        setCompanionHidden(false)
        stickyNote = false
        model.bubble = .greeting(text)
        let timing = Greeting.timing(for: text)
        scheduleDismiss(after: .seconds(timing.typing + timing.hold))
        return true
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
        stickyNote = false
        let wasShowing = model.bubble.isAnswer
        // Only an answer going away stops what produced it. A green "opened Safari" pill
        // timing out (3 s) used to cancel the tutorial still being planned in Safari:
        // green setup, then no lavender walkthrough.
        let wasAnswer = if case .answer = model.bubble { true } else { false }
        if model.bubble.isAnswer { model.bubble = .idle }
        if wasShowing, wasAnswer { onDismiss?() }
    }

    // MARK: - Panels

    static func makePanel(frame: CGRect) -> NSPanel {
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
        // On the current desktop only, brought along on every desktop switch (`followSpaces`):
        // screen-sized and on all desktops at once, the overlays turned every desktop's
        // thumbnail in Mission Control black (gone as soon as ClickBait quit).
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.sharingType = .none  // never in screenshots, screen sharing or thumbnails
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private func makeBubblePanel() {
        let host = NSHostingView(rootView: CompanionBubbleView(model: model))
        let stage = StagePanel(content: host, size: OverlayModel.bubbleCanvas, makePanel: Self.makePanel)
        model.onBubbleSizeChange = { [weak self] in
            guard let self, guide == nil, homeFlight == nil else { return }
            moveBubble(to: anchor ?? NSEvent.mouseLocation)
        }
        stage.panel.orderFrontRegardless()
        bubbleStage = stage
        bubbleHost = host

        guideLabelStage = StagePanel(content: NSHostingView(rootView: GuideLabelView(model: model)),
                                     size: OverlayModel.guideLabelCanvas, makePanel: Self.makePanel)
    }

    /// Brings the overlays to the desktop the user just switched to.
    private func followSpaces() {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bubblePanel?.orderFrontRegardless()
                if let label = self.guideLabelPanel, label.isVisible { label.orderFrontRegardless() }
            }
        }
        spaceObserver = observer
    }

    // MARK: - Bubble position

    /// Where the triangle's centre rests: 35 pt right of and 25 pt below the pointer's
    /// hotspot, as Clicky's (MIT). The system arrow reaches ~12 pt right and 20 pt down, so
    /// the triangle (≤ 9 pt from its centre) clears it.
    private static let triangleOffset = CGSize(width: 35, height: 25)
    /// The companion's top-left corner from the hotspot (the triangle sits `triangleInContent`
    /// inside it).
    private static var cursorClearance: CGSize {
        CGSize(width: triangleOffset.width - triangleInContent, height: triangleOffset.height - triangleInContent)
    }

    // MARK: - Motion

    /// Following the cursor: an underdamped spring, Clicky's feel (MIT) — SwiftUI's
    /// `.spring(response: 0.2, dampingFraction: 0.6)`, whose stiffness (2π/response)² and
    /// damping 2ζω are exactly `Spring(period: response, damping: ζ)`. It overshoots ~9%
    /// of its lag when the mouse stops, then settles. Reduce Motion: critically damped
    /// (no overshoot). (Was an exponential ease, 0.11 s.)
    ///
    /// Motion is driven entirely by the display's refresh: every frame reads the cursor
    /// position. Mouse-moved events can't be used even to wake this up — macOS only
    /// generates them for apps that ask, so over Chrome or Electron apps (Claude) they
    /// arrive late or in bursts, which made the follow feel different from the desktop.
    /// The display's refresh rate also varies (ProMotion drops it over static content
    /// like the desktop), so a steady rate is requested while the companion moves.
    private static let followSpring = Spring(period: 0.2, damping: 0.6)
    private static let calmFollowSpring = Spring(period: 0.2, damping: 1)
    /// The follow's speed (points a second), carried from frame to frame.
    private var followVelocity = CGVector.zero
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
    /// Steady frames while moving, so the glide looks the same over any content. 60 Hz, as
    /// Clicky's 16 ms timer: at 120 every frame was another commit for a busy render server,
    /// and its waits were most of the companion's stalls (stall trap, 2026-10-23).
    private static let movingRate = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
    /// Low rate while still: the cursor is still sampled (to notice movement and hidden
    /// pointers) without keeping a ProMotion display at 120 Hz.
    /// At least 30 Hz: at 10 Hz the first ~100 ms of a movement after a pause looked steppy.
    private static let restingRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 30)

    private func startMotion() {
        anchor = NSEvent.mouseLocation
        followVelocity = .zero
        if let view = bubbleHost {
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
        if let last = lastFrame, now - last > 0.08, companionAlpha > 0,
           guide != nil || homeFlight != nil || anchor != NSEvent.mouseLocation {
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

        updateWaveform(elapsed: elapsed)
        defer { stepTurn(elapsed: elapsed) }
        if guide != nil {
            stepGuide(now: now, elapsed: elapsed, link: link)
            return
        }
        if homeFlight != nil {
            stepHome(now: now, elapsed: elapsed, mouse: mouse, link: link)
            return
        }
        // Spinning and pulsing are motion too: at the resting 30 Hz the thinking spin jumped
        // ~8° a frame and looked choppy.
        let animating = isTurning || model.bubble == .listening || model.isSpinning || model.isPulsing
        if animating, link.preferredFrameRateRange != Self.movingRate {
            link.preferredFrameRateRange = Self.movingRate
        }

        let previous = anchor ?? mouse
        // Still springing (an overshoot passes through the mouse's spot with speed left).
        let springing = followVelocity != .zero || returnVelocity != nil
        guard previous != mouse || springing else {
            // Settled: let the display relax its refresh rate again (unless the
            // triangle is turning or the waveform is moving).
            let wanted = animating ? Self.movingRate : Self.restingRate
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
            if hypot(mouse.x - next.x, mouse.y - next.y) < 4 {  // the follow takes over, at the same speed
                followVelocity = CGVector(dx: vx, dy: vy)
                returnVelocity = nil
            }
        } else {
            let spring = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Self.calmFollowSpring : Self.followSpring
            var vx = Double(followVelocity.dx), vy = Double(followVelocity.dy)
            var x = Double(previous.x), y = Double(previous.y)
            spring.step(&x, velocity: &vx, toward: mouse.x, dt: elapsed)
            spring.step(&y, velocity: &vy, toward: mouse.y, dt: elapsed)
            next = CGPoint(x: x, y: y)
            followVelocity = CGVector(dx: vx, dy: vy)
            // Settled: within a quarter point and barely moving.
            if hypot(mouse.x - next.x, mouse.y - next.y) < 0.25, hypot(vx, vy) < 3 {
                next = mouse
                followVelocity = .zero
            }
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
        guard let stage = bubbleStage else { return }
        let topLeft = restingTopLeft(for: mouse)
        let margin = CompanionBubbleView.canvasMargin
        stage.setOrigin(NSPoint(x: topLeft.x - margin, y: topLeft.y + margin - OverlayModel.bubbleCanvas.height), anchor: mouse)
    }

    /// Top-left corner of the companion beside `mouse`, in AppKit coordinates (y up): always
    /// right of and below the cursor, and near a screen edge it stops there, kept on the
    /// screen, as Clicky's does (user's rule, 2026-10-23; it used to flip to the other side).
    private func restingTopLeft(for mouse: NSPoint) -> NSPoint {
        let content = model.bubbleSize
        let size = (Double(content.width), Double(content.height))
        let bounds = (NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })?.visibleFrame)
            .map { Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
        let offset = (Double(Self.triangleOffset.width), Double(Self.triangleOffset.height))
        let point = Point(x: mouse.x, y: mouse.y)
        let corner = CompanionPlacement.topLeft(mouse: point, content: size, bounds: bounds, offset: offset,
                                                inContent: Double(Self.triangleInContent))
        return NSPoint(x: corner.x, y: corner.y)
    }

    /// The snip is being worked out: red thinking until something else happens.
    func setSnipAnswering(_ on: Bool) {
        model.isSnipThinking = on
    }

    /// The companion shows ClickBait at work: listening, thinking, working, spinning,
    /// pulsing, red over a snip, or pointing and touring. Esc belongs to ClickBait then.
    var looksBusy: Bool {
        switch model.bubble {
        case .listening, .thinking, .explaining, .working: return true
        default: break
        }
        return model.isSpinning || model.isPulsing || model.isSnipThinking || model.isSnipping || model.isTouring || isGuiding
    }

    /// After a taken Esc: back to idle blue at the cursor. Clears only ClickBait's own
    /// pointing, red and words; nothing else on the Mac.
    func resetToIdle() {
        endGuide()
        model.isSnipThinking = false
        dismissTask?.cancel()
        model.bubble = .idle
        setCompanionHidden(false)
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
    /// (the user has probably just clicked the target); so does the mouse reaching the
    /// target, or `dwell` after arriving.
    private struct Guide {
        var targets: [ScreenPointer]
        var index = 0
        /// Unit vector from the target toward where the triangle sits.
        var approach = CGVector(dx: -0.7071, dy: 0.7071)
        /// How far the target's edge is along `approach` (a tour part's outline; else 0):
        /// the tip stops there instead of on top of the thing.
        var edge: CGFloat = 0
        /// The triangle's centre, sprung toward its spot each frame.
        var center: CGPoint
        var velocity = CGVector.zero
        var targetStarted: CFTimeInterval = 0
        /// When the triangle came to rest at the current target (the wait counts from here).
        var settledAt: CFTimeInterval?
        /// Touring the parts of a snipped thing: red, names as labels, shorter stops.
        var isTour = false
        /// A tutorial step: lavender, the instruction as the label, no timeout, and clicks
        /// don't move it on (the tutorial watches the screen for that).
        var isTutorial = false
        /// The reply's own few words for a single target ("Share's up here!"), shown instead
        /// of "this one!".
        var label: String?
        /// The flight to the current spot (Clicky's arc) and when it set off (frame-loop clock).
        var flight: FlightArc?
        var flightStarted: CFTimeInterval = 0
    }

    /// Flying home after pointing: an arc to where the companion rests by the cursor as it
    /// was when the flight began; a mouse that moves on by more than 100 pt ends it (the
    /// follow takes over from there, as Clicky's).
    private struct HomeFlight {
        var arc: FlightArc
        var started: CFTimeInterval
        var mouse: CGPoint
        var center: CGPoint
        var velocity = CGVector.zero
    }
    private var homeFlight: HomeFlight?
    /// From this much of a flight on, the triangle turns from its heading of travel onto
    /// what it's aiming at (with the turn spring), so it lands aimed.
    private static let turnInAt = 0.7
    private static let homeCancelDistance: CGFloat = 100

    private var guide: Guide?
    /// Gliding to a target: eases in, slows down and settles softly (about half a second).
    /// The glide home with Reduce Motion on (flights are off then): critically damped.
    private static let glideSpring = Spring(period: 0.38, damping: 1)
    /// Turning: a little quicker than the glide so the tip leads.
    private static let turnSpring = Spring(period: 0.3, damping: 1)
    /// The angle the triangle is turning toward, and how fast it's turning.
    private var wantedAngle = CompanionTriangle.restingAngle
    private var angleVelocity = 0.0
    // Hold times live in `GuideTiming` (Core), all timed from arrival: 3 s for one blue
    // target, 2 s each for several, 2.4 s per tour part; walkthrough steps wait for a click.
    /// The mouse this close to a blue target means it's been found.
    private static let reachedDistance: CGFloat = 24
    /// Distance from the triangle's centre (its centroid) to its rounded tip — size/√3 less
    /// the corner radius — up to its pulse size, plus a gap.
    private static var tipDistance: CGFloat {
        (CompanionTriangle.size / 3.squareRoot() - EquilateralTriangle.cornerRadius) * 1.2 + 3
    }
    /// The triangle's centre measured from the companion's top-left corner (its measured content).
    private static var triangleInContent: CGFloat {
        CompanionBubbleView.contentPadding + CompanionBubbleView.triangleSpacing + CompanionTriangle.size * 0.85
    }
    /// The triangle's centre measured from the companion panel's (canvas's) top-left corner.
    private static var triangleInset: CGFloat { CompanionBubbleView.canvasMargin + triangleInContent }

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

    /// Planning a walkthrough: lavender with a "planning…" pill at once, instead of idle
    /// blue until the plan arrives. Off again (pill and all) if no tutorial starts.
    func tutorialPlanning(_ on: Bool) {
        if on {
            dismissTask?.cancel()
            setCompanionHidden(false)
            model.bubble = .working(Self.planningLabel)
            setTutoring(true)
        } else {
            if case .working = model.bubble { model.bubble = .idle }
            setTutoring(false)
        }
    }

    /// What a walkthrough shows while it gathers what it needs, before it goes to the dock.
    static let planningLabel = "planning…"

    /// What a walkthrough shows while it works out the next step.
    static let checkingLabel = "checking…"

    func setTutoring(_ on: Bool) {
        model.isTutoring = on
        if !on { model.isTutorialChecking = false }
        if !on {
            if guide?.isTutorial == true { endGuide() }
            if case .hint = model.bubble { model.bubble = .idle }
        }
    }

    /// Points at the current step's target, the instruction in the label. Moving
    /// between steps glides; an unchanged step just follows its target.
    func tutorialPoint(at target: ScreenPointer) {
        model.isTutorialChecking = target.label == Self.checkingLabel
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
    /// A brief "done" tick at the end of a tutorial. It clears while the companion is
    /// still lavender: left up, it turned green when tutoring ended and stayed.
    func tutorialDone(_ text: String) {
        if guide?.isTutorial == true { endGuide() }
        model.bubble = .done(text)
        setCompanionHidden(false)
        scheduleDismiss(after: .milliseconds(1500))
    }

    /// The current step's target isn't on screen: the instruction by the cursor instead.
    func tutorialHint(_ text: String) {
        model.isTutorialChecking = text == Self.checkingLabel
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

    func guide(to targets: [ScreenPointer], label: String? = nil) {
        endGuide()
        endHomeFlight()
        guard !targets.isEmpty else { return }
        // Start from wherever the triangle is drawn now.
        let frame = bubbleStage?.contentFrame ?? .zero
        let start = CGPoint(x: frame.minX + Self.triangleInset, y: frame.maxY - Self.triangleInset)
        guide = Guide(targets: targets, center: start)
        guide?.label = targets.count == 1 ? label : nil
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
        if targets[guide.index] != current {
            guide.targetStarted = CACurrentMediaTime()
            guide.settledAt = nil
        }
        guide.targets = targets
        self.guide = guide
        beginTarget()
        Log.ask.notice("Guide: targets corrected by the close-up")
    }

    /// Back to following the cursor, gliding from wherever the triangle is now.
    func endGuide() {
        guard let guide else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // The cursor position that would put the triangle where it is: the normal follow
            // then glides it back from here.
            anchor = CGPoint(x: guide.center.x - Self.triangleOffset.width, y: guide.center.y + Self.triangleOffset.height)
            returnVelocity = guide.velocity
        } else {
            // An arc to where the companion rests by the cursor now.
            let mouse = NSEvent.mouseLocation
            let rest = restingTopLeft(for: mouse)
            let end = CGPoint(x: rest.x + Self.triangleInContent, y: rest.y - Self.triangleInContent)
            homeFlight = HomeFlight(arc: FlightArc(from: Point(x: guide.center.x, y: guide.center.y), to: Point(x: end.x, y: end.y)),
                                    started: CACurrentMediaTime(), mouse: mouse, center: guide.center)
            anchor = mouse
            returnVelocity = nil
        }
        followVelocity = .zero
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
        let outline = guide.targets[guide.index].outline
        let reach = 40 + (outline?.radius(toward: direction.dx, direction.dy) ?? 0)
        let spot = CGPoint(x: point.x + direction.dx * reach, y: point.y + direction.dy * reach)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
           !screen.visibleFrame.insetBy(dx: 10, dy: 10).contains(spot) {
            direction = CGVector(dx: -direction.dx, dy: -direction.dy)
        }
        guide.approach = direction
        guide.edge = outline?.radius(toward: direction.dx, direction.dy) ?? 0
        guide.targetStarted = CACurrentMediaTime()
        guide.settledAt = nil
        self.guide = guide

        let label = guide.targets[guide.index].label
        model.guideLabel = guide.isTour || guide.isTutorial
            ? label  // the part's name ("probably supraspinatus")
            : guide.label ?? GuidePhrase.next(step: guide.index, of: guide.targets.count, avoiding: model.guideLabel)
        model.guideTarget = label.isEmpty ? nil : label
        model.isGuiding = true
        onGuide?()
        showGuideLabel()
    }

    private func stepGuide(now: CFTimeInterval, elapsed: CFTimeInterval, link: CADisplayLink) {
        guard var guide else { return }
        let target = guide.targets[guide.index].appKit
        let point = CGPoint(x: target.x, y: target.y)
        if let hold = GuideTiming.hold(isTour: guide.isTour, isTutorial: guide.isTutorial, targetCount: guide.targets.count) {
            // Held from arrival (not from setting off); blue also ends when the mouse gets there.
            let clock = CACurrentMediaTime()
            if let settledAt = guide.settledAt, clock - settledAt > hold {
                advanceGuide(reason: "timeout")
                return
            }
            if !guide.isTour {
                let mouse = NSEvent.mouseLocation
                if hypot(mouse.x - point.x, mouse.y - point.y) < Self.reachedDistance {
                    advanceGuide(reason: "mouse reached it")
                    return
                }
            }
            if clock - guide.targetStarted > GuideTiming.maxStop {
                advanceGuide(reason: "never settled")
                return
            }
        }
        let reach = Self.tipDistance + guide.edge
        let spot = CGPoint(x: point.x + guide.approach.dx * reach, y: point.y + guide.approach.dy * reach)

        var next = guide.center
        var heading: Double?
        var progress: Double?  // nil: no flight (Reduce Motion), arrival is immediate
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            next = spot
            guide.velocity = .zero
            guide.flight = nil
            setFlightScale(1)
        } else {
            // A new or corrected spot: fly there from wherever the triangle is now. The flight
            // ends exactly where the glide did (the tip at the target's edge, same side).
            let moved = guide.flight.map { hypot($0.end.x - spot.x, $0.end.y - spot.y) > 0.5 } ?? (next != spot)
            if moved {
                guide.flight = FlightArc(from: Point(x: next.x, y: next.y), to: Point(x: spot.x, y: spot.y))
                guide.flightStarted = now
                guide.settledAt = nil  // a new or corrected flight: not there yet
            }
            if let flight = guide.flight {
                let flown = flight.progress(after: now - guide.flightStarted)
                progress = flown
                let progress = flown
                let eased = FlightArc.smoothstep(progress)
                let at = flight.point(at: eased)
                next = progress >= 1 ? spot : CGPoint(x: at.x, y: at.y)
                guide.velocity = progress >= 1 ? .zero
                    : CGVector(dx: (next.x - guide.center.x) / elapsed, dy: (next.y - guide.center.y) / elapsed)
                if progress < Self.turnInAt { heading = flight.heading(at: eased) }
                setFlightScale(progress >= 1 ? 1 : flight.scale(at: progress))
            }
        }
        let moving = next != guide.center
        guide.center = next

        // Point the vertex at the target (0° = up, clockwise; AppKit's y points up).
        // One heading per stop — from where the triangle will rest toward the target —
        // so it turns once and holds still (aiming from its moving position made the tip
        // wobble as it arrived).
        // While flying: facing the way it travels, until `turnInAt`.
        wantedAngle = heading ?? atan2(-guide.approach.dx, -guide.approach.dy) * 180 / .pi

        // Arrived only once flown there and turned onto the target: the hold (and the pulse)
        // count from here. (Counting from the first frame, before the flight had moved, a blue
        // point left ~1 s after setting off.)
        if guide.settledAt == nil,
           GuideTiming.hasArrived(flightProgress: progress, distanceToSpot: hypot(spot.x - next.x, spot.y - next.y),
                                  isTurning: isTurning) {
            let clock = CACurrentMediaTime()
            guide.settledAt = clock
            Log.ask.notice("Guide: arrived at target \(guide.index + 1, privacy: .public) after \(String(format: "%.2f", clock - guide.targetStarted), privacy: .public) s")
        }
        self.guide = guide
        let arrived = guide.settledAt != nil
        if model.isGuideSettled != arrived { model.isGuideSettled = arrived }  // pulse once arrived

        let wanted: CAFrameRateRange = moving || isTurning || model.isPulsing || model.isSpinning ? Self.movingRate : Self.restingRate
        if link.preferredFrameRateRange != wanted { link.preferredFrameRateRange = wanted }

        bubbleStage?.setOrigin(NSPoint(x: next.x - Self.triangleInset,
                                       y: next.y + Self.triangleInset - OverlayModel.bubbleCanvas.height), anchor: next)
        placeGuideLabel(triangleCenter: next, awayFrom: guide.approach, elapsed: elapsed)
    }

    /// One frame of the flight home. Faces its way of travel, then turns back to rest.
    private func stepHome(now: CFTimeInterval, elapsed: CFTimeInterval, mouse: CGPoint, link: CADisplayLink) {
        guard var home = homeFlight else { return }
        if link.preferredFrameRateRange != Self.movingRate { link.preferredFrameRateRange = Self.movingRate }
        // The user moved on: follow from here, at the flight's speed.
        if hypot(mouse.x - home.mouse.x, mouse.y - home.mouse.y) > Self.homeCancelDistance {
            anchor = CGPoint(x: home.center.x - Self.triangleOffset.width, y: home.center.y + Self.triangleOffset.height)
            followVelocity = home.velocity
            endHomeFlight()
            Log.app.notice("Flight home: the mouse moved on; following")
            return
        }
        let progress = home.arc.progress(after: now - home.started)
        let eased = FlightArc.smoothstep(progress)
        let at = home.arc.point(at: eased)
        let next = CGPoint(x: at.x, y: at.y)
        home.velocity = CGVector(dx: (next.x - home.center.x) / elapsed, dy: (next.y - home.center.y) / elapsed)
        home.center = next
        wantedAngle = progress < Self.turnInAt ? home.arc.heading(at: eased) ?? CompanionTriangle.restingAngle
            : CompanionTriangle.restingAngle
        bubbleStage?.setOrigin(NSPoint(x: next.x - Self.triangleInset,
                                       y: next.y + Self.triangleInset - OverlayModel.bubbleCanvas.height), anchor: next)
        if progress >= 1 {
            // Landed where the follow would have put it for that mouse spot: it takes over.
            anchor = home.mouse
            endHomeFlight()
            return
        }
        homeFlight = home
        setFlightScale(home.arc.scale(at: progress))
    }

    private func endHomeFlight() {
        homeFlight = nil
        setFlightScale(1)
    }

    /// The swell, set only when it changes visibly (each change redraws the triangle view).
    private func setFlightScale(_ scale: Double) {
        let value = CGFloat(scale)
        guard value != model.flightScale, value == 1 || abs(value - model.flightScale) >= 0.01 else { return }
        model.flightScale = value
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
    /// animation (which restarted every frame while gliding and stuttered). The spring runs
    /// on its own exact angle; the view (a SwiftUI update each time) only hears of changes
    /// it could show — 0.25° or more, and the final settle — since flights turn all the way.
    private func stepTurn(elapsed: CFTimeInterval) {
        guard isTurning || springAngle != nil else { return }
        let current = springAngle ?? model.triangleAngle
        var delta = (wantedAngle - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let target = current + delta
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            model.triangleAngle = target
            angleVelocity = 0
            springAngle = nil
            return
        }
        var angle = current
        Self.turnSpring.step(&angle, velocity: &angleVelocity, toward: target, dt: elapsed)
        if Spring.isSettled(angle, velocity: angleVelocity, target: target, tolerance: 0.2) {
            angleVelocity = 0
            springAngle = nil
            model.triangleAngle = target
            return
        }
        springAngle = angle
        if abs(angle - model.triangleAngle) >= 0.25 { model.triangleAngle = angle }
    }

    /// The turn spring's exact angle while turning (the view gets it in 0.25° steps).
    private var springAngle: Double?

    // MARK: - Listening waveform

    /// The microphone's current level (RMS, 0…1) while listening.
    var levelSource: (() -> Float)?
    private var waveEnvelope: Double = 0
    private var wavePeakRMS: Double = 0

    /// Follows the voice (`WaveformMeter.level`): loudness on a −45…−15 dB scale, rising at
    /// once and falling ×0.72 per ~21 ms as Clicky's, timed by the frame so any refresh rate
    /// looks the same.
    private func updateWaveform(elapsed: CFTimeInterval) {
        guard model.bubble == .listening else {
            if model.waveLevel != 0 { model.waveLevel = 0 }
            if wavePeakRMS > 0 {
                // What the bars had to show this time: the loudest sound and how high it took them.
                Log.app.notice("Waveform: loudest RMS \(String(format: "%.4f", self.wavePeakRMS), privacy: .public) → level \(String(format: "%.2f", WaveformMeter.loudness(rms: self.wavePeakRMS)), privacy: .public)")
                wavePeakRMS = 0
            }
            waveEnvelope = 0
            return
        }
        let rms = Double(levelSource?() ?? 0)
        wavePeakRMS = max(wavePeakRMS, rms)
        waveEnvelope = WaveformMeter.level(after: waveEnvelope, rms: rms, dt: elapsed)
        if abs(model.waveLevel - waveEnvelope) > 0.005 { model.waveLevel = waveEnvelope }
    }

    /// Beside the triangle on the side away from the target (left of it when the target
    /// is to the left), so the label never covers what it's pointing at.
    private func placeGuideLabel(triangleCenter c: CGPoint, awayFrom approach: CGVector, elapsed: CFTimeInterval) {
        guard let stage = guideLabelStage else { return }
        let size = model.guideLabelSize
        // Away from the target, and always fully inside the screen's visible area (below
        // the menu bar, above the Dock): the other side, or pushed in, when it won't fit.
        // The view pads the pill by 6 pt for its shadow; that padding may overhang.
        let screen = NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let spot = PillPlacement.beside(
            Point(x: c.x, y: c.y), width: size.width - 12, height: size.height - 12, gap: 12, preferRight: approach.dx >= 0,
            bounds: Rect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height))
        let target = CGPoint(x: spot.x - 6, y: spot.top + 6 - OverlayModel.guideLabelCanvas.height)
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
        stage.setOrigin(origin, anchor: c)
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
            if guide != nil { advanceGuide(reason: "click") } else if !stickyNote { dismissAnswer() }
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
        case .answer, .done, .error, .jobResult, .greeting: return true  // a click or Escape clears these
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
