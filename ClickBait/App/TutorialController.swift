import AppKit
import ClickBaitCore

/// Walks the user through a multi-step how-to on their own screen: the lavender
/// companion points at each step's target with the instruction in its label, and the
/// screen is watched until the step is done — cheapest signals first:
/// - a click on the current target (every ¼ s),
/// - the app's own clickable elements (every ¾ s): the target appearing, a later step's
///   target appearing (the user went ahead), or the menu to open when the target is
///   inside a closed menu,
/// - a tiny screen sample (about once a second, only while the target can't be found)
///   to notice the screen changing,
/// - and only when a change can't be explained that way, the model looking at the
///   screen (at most every 6 s).
/// Screenshots stay in memory; nothing is kept. Esc, closing the chat, a new question
/// or a blocked app ends it.
@MainActor
final class TutorialController {
    /// The chat's reply, rewritten as steps tick off.
    var onChecklist: ((String) -> Void)?
    /// Finished (`message` for the user, nil when stopped by them).
    var onFinished: ((String?) -> Void)?
    var speak: ((String) -> Void)?

    private(set) var isActive = false
    private let overlay: OverlayController
    private let capturer = ScreenCapturer()

    private var plan = TutorialPlan(intro: "", steps: [])
    private var goal = ""
    private var index = 0
    private var speakSteps = false
    private var provider: (any LLMProvider)?
    private var context = ScreenContext()
    private var blocklist = AppBlocklist.defaults
    private var loop: Task<Void, Never>?

    private var startedAt = Date()
    private var lastProgress = Date()
    private var pendingClick: (point: Point, at: Date)?
    /// What the companion points at now (Quartz), and whether it's a menu to open first
    /// rather than the step's own target.
    private var currentFrame: Rect?
    private var pointingAtMenu = false
    private var targetMissingSince: Date?
    private var lastSample: [UInt8]?
    private var screenChangedAt: Date?
    private var lastModelCheck = Date.distantPast
    private var checking = false
    private var menuPaths: [Int: [String]] = [:]
    /// Steps whose menu search already ran (found or not): it isn't repeated every tick.
    private var menuSearched = Set<Int>()
    /// The planned steps are all done: check the task is finished, or plan what's left.
    private var needsContinuation = false
    private var continuations = 0
    private static let maxContinuations = 2
    /// A target that vanishes briefly (a menu redrawing) keeps the pointer this long
    /// before the companion falls back to showing the instruction.
    private static let missingGrace: TimeInterval = 1.5

    private static let tick: Duration = .milliseconds(250)
    private static let maxDuration: TimeInterval = 300
    private static let maxIdle: TimeInterval = 90
    private static let modelCheckInterval: TimeInterval = 6

    init(overlay: OverlayController) {
        self.overlay = overlay
    }

    func start(_ plan: TutorialPlan, goal: String, provider: any LLMProvider, context: ScreenContext,
               blocklist: AppBlocklist, speak speakSteps: Bool) {
        stop(message: nil)
        self.plan = plan
        self.goal = goal
        self.provider = provider
        self.context = context
        self.blocklist = blocklist
        self.speakSteps = speakSteps
        index = 0
        startedAt = Date()
        lastProgress = Date()
        pendingClick = nil
        currentFrame = nil
        targetMissingSince = nil
        lastSample = nil
        screenChangedAt = nil
        menuPaths = [:]
        menuSearched = []
        needsContinuation = false
        continuations = 0
        isActive = true
        overlay.setTutoring(true)
        Log.ask.notice("Tutorial started: \(plan.steps.count, privacy: .public) steps")
        onChecklist?(checklistText)
        loop = Task { [weak self] in await self?.run() }
    }

    /// Esc, a closed chat, a new question: end now. `message` is shown when given.
    func stop(message: String?) {
        guard isActive else { return }
        isActive = false
        loop?.cancel()
        loop = nil
        overlay.setTutoring(false)
        Log.ask.notice("Tutorial ended at step \(self.index + 1, privacy: .public) of \(self.plan.steps.count, privacy: .public)")
        onFinished?(message)
    }

    /// Every left click anywhere (global AppKit point).
    func noteClick(_ point: NSPoint) {
        guard isActive else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        pendingClick = (Point(x: point.x, y: primaryHeight - point.y), Date())
    }

    private var checklistText: String {
        let intro = plan.intro.isEmpty ? "" : plan.intro + "\n\n"
        return intro + plan.checklist(done: index)
    }

    private var instruction: String {
        var text = plan.steps[index].instruction.lowercased()
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: - Watching

    private func run() async {
        if speakSteps { speak?(plan.steps[0].instruction) }
        var tick = 0
        while isActive, !Task.isCancelled {
            await check(tick: tick)
            tick += 1
            try? await Task.sleep(for: Self.tick)
        }
    }

    private func check(tick: Int) async {
        guard isActive else { return }
        if Date().timeIntervalSince(startedAt) > Self.maxDuration || Date().timeIntervalSince(lastProgress) > Self.maxIdle {
            stop(message: "I stopped the tutorial. Ask again any time.")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        if blocklist.isBlocked(bundleID: front?.bundleIdentifier) {
            stop(message: "Tutorial stopped: ClickBait doesn't look at \(front?.localizedName ?? "that app").")
            return
        }

        // A click on what the companion points at: the step is done (or the menu that
        // hides it is now open). Checked after a moment, once the click has landed.
        var refreshNow = false
        if let click = pendingClick, Date().timeIntervalSince(click.at) >= 0.35 {
            pendingClick = nil
            if let frame = currentFrame, Self.contains(frame, click.point, margin: 10), !pointingAtMenu {
                advance(to: index + 1, reason: "clicked")
                return
            }
            refreshNow = true  // something else was clicked (a menu opened?): look again now
        }

        if needsContinuation {
            await continueOrFinish()
            return
        }

        guard refreshNow || tick % 2 == 0 else { return }
        let pid = front?.processIdentifier
        let display = Self.displayUnderMouse()
        let elements = await Task.detached(priority: .userInitiated) {
            AXInspector.visibleElements(frontmostPID: pid, display: display)
        }.value
        guard isActive else { return }

        let step = plan.steps[index]
        if let target = StepMatcher.find(step.target, in: elements) {
            point(at: target.frame, label: instruction, menu: false)
            return
        }
        // The user may have gone ahead (a later step's target is showing).
        for later in (index + 1)..<min(index + 3, plan.steps.count) where StepMatcher.find(plan.steps[later].target, in: elements) != nil {
            advance(to: later, reason: "went ahead")
            return
        }
        // Inside a closed menu? Point at the menu to open first.
        if menuSearched.insert(index).inserted, let path = await Task.detached(priority: .userInitiated, operation: {
            AXInspector.menuPath(to: step.target, frontmostPID: pid)
        }).value {
            menuPaths[index] = path
            Log.ask.notice("Tutorial: step \(self.index + 1, privacy: .public) is inside a menu (\(path.count - 1, privacy: .public) to open)")
        }
        if let path = menuPaths[index] {
            let opening = path.dropLast().reversed().compactMap { title in
                StepMatcher.find(title, in: elements).map { (title, $0) }
            }.first
            if let (title, element) = opening {
                point(at: element.frame, label: "open \(title.lowercased()) first", menu: true)
                return
            }
        }

        // Nowhere to point. Give it a moment (menus redraw, windows animate) before
        // the companion leaves the last spot to show the instruction instead.
        if targetMissingSince == nil { targetMissingSince = Date() }
        if let since = targetMissingSince, Date().timeIntervalSince(since) >= Self.missingGrace {
            currentFrame = nil
            pointingAtMenu = false
            overlay.tutorialHint(instruction)
        }
        await sampleScreen()
        if let since = targetMissingSince, Date().timeIntervalSince(since) > 2, !checking,
           Date().timeIntervalSince(lastModelCheck) > Self.modelCheckInterval,
           screenChangedAt.map({ Date().timeIntervalSince($0) < 10 }) ?? false || Date().timeIntervalSince(since) > 8 {
            await askModel()
        }
    }

    private func point(at frame: Rect, label: String, menu: Bool) {
        currentFrame = frame
        pointingAtMenu = menu
        targetMissingSince = nil
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = Point(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        overlay.tutorialPoint(at: ScreenPointer(label: label, appKit: Point(x: center.x, y: primaryHeight - center.y), quartz: center))
    }

    private func advance(to next: Int, reason: String) {
        guard isActive, next > index || next < index else { return }
        index = min(next, plan.steps.count)
        lastProgress = Date()
        currentFrame = nil
        pointingAtMenu = false
        targetMissingSince = nil
        Log.ask.notice("Tutorial: step \(self.index + 1, privacy: .public) of \(self.plan.steps.count, privacy: .public) (\(reason, privacy: .public))")
        onChecklist?(checklistText)
        if index >= plan.steps.count {
            needsContinuation = true  // check it's really done; plan the rest if not
        } else if speakSteps {
            speak?(plan.steps[index].instruction)
        }
    }

    /// All planned steps are done. The model's plans are often short ("click Share" for
    /// a longer task), so look at the screen: finished → done; otherwise plan the next
    /// steps from here and carry on (a couple of times at most).
    private func continueOrFinish() async {
        needsContinuation = false
        guard continuations < Self.maxContinuations, plan.steps.count < TutorialPlan.maxSteps, let provider else {
            finish()
            return
        }
        // The companion stays where it is while ClickBait looks (no flying back and forth).
        if let frame = currentFrame {
            point(at: frame, label: "checking…", menu: pointingAtMenu)
        } else {
            overlay.tutorialHint("checking…")
        }
        try? await Task.sleep(for: .milliseconds(600))  // let the last click take effect
        guard isActive else { return }
        guard let capture = try? await capturer.captureDisplayUnderCursor(excluding: blocklist),
              let encoded = try? ScreenshotEncoder.encode(capture.image) else { finish(); return }
        guard isActive else { return }
        // One call: the planner answers "no steps" when the task is already finished.

        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let display = Self.displayUnderMouse()
        let elements = await Task.detached(priority: .userInitiated) {
            AXInspector.visibleElements(frontmostPID: pid, display: display)
        }.value
        let geometry = capture.geometry(imageWidth: encoded.width, imageHeight: encoded.height)
        let done = plan.steps.map(\.instruction).joined(separator: "; ")
        let question = "\(goal)\nAlready done: \(done).\nWhat are the remaining clicks from the screen as it is now? If it's finished, reply with no steps."
        var next = AskRequest(question: question, screenshotJPEG: encoded.jpeg, screenshotWidth: encoded.width,
                              screenshotHeight: encoded.height, context: context,
                              elements: PromptElement.list(elements, geometry: geometry, question: goal, limit: 40))
        next.planTutorial = true
        let reply = await Self.reply(from: provider, to: next, within: .seconds(25))
        guard isActive else { return }  // stopped meanwhile: stay stopped
        guard let reply, let more = TutorialPlan.parse(reply), !more.steps.isEmpty else {
            finish()
            return
        }
        continuations += 1
        let room = TutorialPlan.maxSteps - plan.steps.count
        plan.steps += more.steps.prefix(room)
        lastProgress = Date()
        menuSearched = []
        Log.ask.notice("Tutorial: planned \(min(more.steps.count, room), privacy: .public) more step(s)")
        onChecklist?(checklistText)
        if speakSteps { speak?(plan.steps[index].instruction) }
    }

    private func finish() {
        guard isActive else { return }  // stopped by the user: never "finish" afterwards
        isActive = false
        loop?.cancel()
        loop = nil
        overlay.tutorialHint("done!")
        if speakSteps { speak?("Done!") }
        Log.ask.notice("Tutorial finished")
        onFinished?("Done!")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !isActive else { return }
            overlay.setTutoring(false)
        }
    }

    // MARK: - Screen and model

    /// A tiny grey copy of the screen compared with the last one: did anything change?
    private func sampleScreen() async {
        guard let capture = try? await capturer.captureDisplayUnderCursor(excluding: blocklist, width: 128) else { return }
        let width = 32, height = 20
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(capture.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return }
        if let last = lastSample {
            let difference = zip(pixels, last).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / pixels.count
            if difference > 4 { screenChangedAt = Date() }
        }
        lastSample = pixels
    }

    /// The model looks at the screen: which step is next, or is it done?
    private func askModel() async {
        guard let provider else { return }
        checking = true
        lastModelCheck = Date()
        defer { checking = false }
        guard let capture = try? await capturer.captureDisplayUnderCursor(excluding: blocklist),
              let encoded = try? ScreenshotEncoder.encode(capture.image), isActive else { return }
        var request = AskRequest(question: goal, screenshotJPEG: encoded.jpeg, screenshotWidth: encoded.width,
                                 screenshotHeight: encoded.height, context: context)
        request.tutorialCheck = (plan, index + 1)
        let start = ContinuousClock.now
        guard let reply = await Self.reply(from: provider, to: request, within: .seconds(15)),
              let progress = TutorialProgress.parse(reply), isActive else { return }
        Log.ask.notice("Tutorial check: next step \(progress.nextStep, privacy: .public), done \(progress.done, privacy: .public) (\(String(describing: ContinuousClock.now - start), privacy: .public))")
        if progress.done {
            advance(to: plan.steps.count, reason: "model: done")
        } else if (1...plan.steps.count).contains(progress.nextStep), progress.nextStep - 1 > index {
            // Only ever forward: a screenshot can't tell an undone step from one whose
            // effect isn't visible, and going back confused users.
            advance(to: progress.nextStep - 1, reason: "model")
        }
    }

    private nonisolated static func reply(from provider: any LLMProvider, to request: AskRequest, within limit: Duration) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var text = ""
                do { for try await chunk in provider.stream(request) { text += chunk } } catch { return nil }
                return text
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func contains(_ frame: Rect, _ point: Point, margin: Double) -> Bool {
        point.x >= frame.minX - margin && point.x <= frame.maxX + margin && point.y >= frame.minY - margin && point.y <= frame.maxY + margin
    }

    private static func displayUnderMouse() -> Rect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return Rect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
