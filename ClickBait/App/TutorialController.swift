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
    /// Opens or switches to an app (green "opening Notes…" / "opened Notes"): true once
    /// it's in front. For steps in another app.
    var openApp: ((String) async -> Bool)?
    /// Whether a name is an installed app ("Notes").
    var isInstalledApp: (String) -> Bool = { _ in false }

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
    /// The role of what the companion points at (AXButton…), and of the last step clicked.
    private var currentRole: String?
    private var lastClicked: (target: String, role: String?)?
    private var pointingAtMenu = false
    private var targetMissingSince: Date?
    private var lastSample: [UInt8]?
    private var screenChangedAt: Date?
    private var lastModelCheck = Date.distantPast
    /// When the user last completed a step by clicking: if the next target doesn't show
    /// up right after, the click may have finished the task (a dialog closing).
    private var clickedStepAt: Date?
    private var loggedTarget: Int?
    private var checking = false
    private var menuPaths: [Int: [String]] = [:]
    /// Steps whose menu search already ran (found or not): it isn't repeated every tick.
    private var menuSearched = Set<Int>()
    /// The user clicked the menu the companion pointed at: it's open, so its items are
    /// looked up directly (toggled by another click on it, cleared by any other click).
    private var menuOpened = false
    /// The menu the user just opened by clicking a "Open the … menu" step: the next step's
    /// item is inside it, so point at the item rather than at the menu again.
    private var openedMenu: String?
    /// Steps whose app was switched to already: the user leaving it again isn't fought.
    private var switchedFor = Set<Int>()
    /// The page that was open when a typing step began: a different one means it's done.
    private var addressAtStep: (index: Int, address: String?)?
    /// When a shortcut step began, and the clipboard then: ⌘C is done when it changes,
    /// other shortcuts when the screen does. Keys themselves are never read.
    private var shortcutStart: (index: Int, at: Date, clipboard: Int)?
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

    /// `continues`: plan more once the steps run out (off when the steps are the whole task).
    func start(_ plan: TutorialPlan, goal: String, provider: any LLMProvider, context: ScreenContext,
               blocklist: AppBlocklist, speak speakSteps: Bool, continues: Bool = true) {
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
        menuOpened = false
        switchedFor = []
        needsContinuation = false
        continuations = continues ? 0 : Self.maxContinuations
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
            if let frame = currentFrame, Self.contains(frame, click.point, margin: 10), !pointingAtMenu,
               plan.steps[index].typing == nil {  // clicking into a field isn't typing in it
                advance(to: index + 1, reason: "clicked")
                return
            }
            if let frame = currentFrame, pointingAtMenu, Self.contains(frame, click.point, margin: 10) {
                menuOpened.toggle()
            } else {
                menuOpened = false
            }
            if let frame = currentFrame {
                let dx = max(frame.minX - click.point.x, 0, click.point.x - frame.maxX)
                let dy = max(frame.minY - click.point.y, 0, click.point.y - frame.maxY)
                Log.ask.notice("Tutorial: click \(Int((dx * dx + dy * dy).squareRoot()), privacy: .public) pt from the target\(self.pointingAtMenu ? " (a menu to open)" : "", privacy: .public)")
            }
            refreshNow = true  // something else was clicked (a menu opened?): look again now
        }

        if needsContinuation {
            await continueOrFinish()
            return
        }

        // This step happens in another app: switch there (green), once per step — unless
        // the step just clicked opens that app ("System Settings…"): give it time to come.
        let opening = index > 0 && plan.steps[index].app.map { plan.steps[index - 1].opensApp($0) } == true
            && Date().timeIntervalSince(lastProgress) < 4
        if let wanted = plan.steps[index].app, !Self.isApp(wanted, front), isInstalledApp(wanted), !opening,
           switchedFor.insert(index).inserted, let openApp {
            await switchApp(to: wanted, using: openApp)
            return
        }

        // Keep a recent screen sample at all times, so a change (a dialog closing) shows
        // up the moment it happens rather than after a fresh baseline.
        if tick % 4 == 0 { await sampleScreen() }

        // A shortcut to press (⌘C, ⌘V): nothing to point at; the instruction by the cursor.
        let step = plan.steps[index]
        if step.isShortcut {
            if shortcutStart?.index != index {
                shortcutStart = (index, Date(), NSPasteboard.general.changeCount)
                currentFrame = nil
                overlay.tutorialHint(instruction)
            }
            guard let start = shortcutStart else { return }
            let pressed = step.copiesToClipboard
                ? NSPasteboard.general.changeCount != start.clipboard
                : screenChangedAt.map { $0.timeIntervalSince(start.at) > 1.2 } ?? false
            if pressed { advance(to: index + 1, reason: "shortcut") }
            return
        }

        guard refreshNow || tick % 2 == 0 else { return }
        let pid = front?.processIdentifier
        // A typing step in a browser is done once the page changes (to the typed site).
        if plan.steps[index].typing != nil {
            let page = await Task.detached(priority: .userInitiated) { () -> String? in
                var trace = ""
                return AXInspector.pageAddress(frontmostPID: pid, trace: &trace)?.address
            }.value
            guard isActive else { return }
            if addressAtStep?.index != index { addressAtStep = (index, page) }
            if let page, Self.typingDone(plan.steps[index], page: page, before: addressAtStep?.address) {
                advance(to: index + 1, reason: "typed")
                return
            }
        }
        let display = Self.displayUnderMouse()
        let elements = await Task.detached(priority: .userInitiated) {
            AXInspector.visibleElements(frontmostPID: pid, display: display)
        }.value
        guard isActive else { return }

        // Typing a web address: the address bar, found by its shape.
        if step.typedHost != nil, let bar = await Task.detached(priority: .userInitiated, operation: {
            AXInspector.addressBarFrame(frontmostPID: pid)
        }).value {
            if loggedTarget != index {
                loggedTarget = index
                Log.ask.notice("Tutorial: step \(self.index + 1, privacy: .public) points at the address bar")
            }
            point(at: bar, label: instruction, menu: false)
            return
        }
        // A near-exact visible match wins; a looser one ("History" button for "Clear
        // History…") only if the target isn't an item in the app's menus.
        var visible = StepMatcher.find(step.target, in: elements, minimum: 0.95)
        if visible == nil, let loose = StepMatcher.find(step.target, in: elements) {
            if menuSearched.insert(index).inserted, let path = await Task.detached(priority: .userInitiated, operation: {
                AXInspector.menuPath(to: step.target, frontmostPID: pid)
            }).value {
                menuPaths[index] = path
            }
            if menuPaths[index] == nil { visible = loose }
        }
        if let target = visible {
            if loggedTarget != index {
                loggedTarget = index
                Log.ask.notice("Tutorial: step \(self.index + 1, privacy: .public) points at a \(target.kind, privacy: .public)")
            }
            point(at: target.frame, label: instruction, menu: false)
            currentRole = target.role
            await checkForCompletion()
            return
        }
        // The user may have gone ahead (a later step's target is showing) — only in the app
        // that step belongs to: Finder's own search field once "skipped" System Settings.
        for later in (index + 1)..<min(index + 3, plan.steps.count)
        where plan.steps[later].app.map({ Self.isApp($0, front) }) ?? true
            && StepMatcher.find(plan.steps[later].target, in: elements) != nil {
            advance(to: later, reason: "went ahead")
            return
        }
        // Inside a closed menu? Point at the menu to open first.
        if menuSearched.insert(index).inserted, let path = await Task.detached(priority: .userInitiated, operation: {
            AXInspector.menuPath(to: step.target, frontmostPID: pid)
        }).value {
            menuPaths[index] = path
            Log.ask.notice("Tutorial: step \(self.index + 1, privacy: .public) is inside a menu (\(path.count - 1, privacy: .public) to open): \(path.joined(separator: " ▸ "), privacy: .public)")
            // Opening that menu becomes a step of the plan, so the pill and the chat's
            // checklist list the same steps (the pill used to say "open view first" on its own).
            if insertMenuSteps(path) { return }
        }
        // The menu holding it is open (the user just clicked it): point at the item.
        if menuOpened || menuPaths[index]?.first == openedMenu, let path = menuPaths[index], let frame = await Task.detached(priority: .userInitiated, operation: {
            AXInspector.openMenuItemFrame(path, frontmostPID: pid)
        }).value {
            if loggedTarget != index {
                loggedTarget = index
                Log.ask.notice("Tutorial: step \(self.index + 1, privacy: .public) points at an item in the open menu")
            }
            point(at: frame, label: instruction, menu: false)
            return
        }
        if let path = menuPaths[index] {
            let opening = path.dropLast().reversed().compactMap { title in
                StepMatcher.find(title, in: elements).map { (title, $0) }
            }.first
            if let (title, element) = opening {
                point(at: element.frame, label: "open \(title.lowercased()) first", menu: true)
                await checkForCompletion()
                return
            }
        }

        // Nowhere to point. Give it a moment (menus redraw, windows animate) before
        // the companion leaves the last spot to show the instruction instead.
        if targetMissingSince == nil { targetMissingSince = Date() }
        if let since = targetMissingSince, Date().timeIntervalSince(since) >= Self.missingGrace {
            if let frame = currentFrame {
                // Stay where it was (lists come back incomplete while a menu is open);
                // flying home and back out looked jumpy. The label shows what to do.
                point(at: frame, label: instruction, menu: pointingAtMenu, keepMissing: true)
            } else {
                overlay.tutorialHint(instruction)  // never had a target this step
            }
        }
        guard let since = targetMissingSince, !checking else { return }
        let missingFor = Date().timeIntervalSince(since)
        // Right after a step's click and the next target nowhere: maybe that click
        // finished the task. Ask at once instead of waiting.
        if let clicked = clickedStepAt, Date().timeIntervalSince(clicked) < 4, missingFor > 1.2 {
            clickedStepAt = nil
            await askModel()
            return
        }
        if missingFor > 2, Date().timeIntervalSince(lastModelCheck) > Self.modelCheckInterval,
           screenChangedAt.map({ Date().timeIntervalSince($0) < 10 }) ?? false || missingFor > 8 {
            await askModel()
        }
    }

    private func point(at frame: Rect, label: String, menu: Bool, keepMissing: Bool = false) {
        if frame != currentFrame { currentRole = nil }  // set again by the caller when known
        currentFrame = frame
        pointingAtMenu = menu
        if !keepMissing { targetMissingSince = nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = Point(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        overlay.tutorialPoint(at: ScreenPointer(label: label, appKit: Point(x: center.x, y: primaryHeight - center.y), quartz: center))
    }

    /// Puts "Open the View menu" (and any submenu) into the plan before the current step,
    /// unless the step before already opens it. False when nothing was added.
    private func insertMenuSteps(_ path: [String]) -> Bool {
        let previous = index > 0 ? TutorialPlan.withoutEllipsis(plan.steps[index - 1].target).lowercased() : nil
        let openers = path.dropLast().filter { TutorialPlan.withoutEllipsis($0).lowercased() != previous }
        guard !openers.isEmpty, openers.count == path.count - 1, plan.steps.count + openers.count <= TutorialPlan.maxSteps else {
            return false
        }
        let app = plan.steps[index].app
        let steps = openers.enumerated().map { offset, title in
            TutorialStep(target: title, instruction: offset == 0 ? "Open the \(title) menu" : "Open \(title)", app: app)
        }
        plan.steps.insert(contentsOf: steps, at: index)
        // Everything kept per step moves along with its step.
        menuPaths = Dictionary(uniqueKeysWithValues: menuPaths.map { ($0.key >= index ? $0.key + steps.count : $0.key, $0.value) })
        menuSearched = Set(menuSearched.map { $0 >= index ? $0 + steps.count : $0 })
        loggedTarget = nil
        Log.ask.notice("Tutorial: added \(steps.count, privacy: .public) menu step(s) before step \(self.index + steps.count + 1, privacy: .public)")
        onChecklist?(checklistText)
        if speakSteps { speak?(plan.steps[index].instruction) }
        return true
    }

    private func advance(to next: Int, reason: String) {
        guard isActive, next > index || next < index else { return }
        lastClicked = reason == "clicked" && index < plan.steps.count ? (plan.steps[index].target, currentRole) : nil
        openedMenu = reason == "clicked" && index < plan.steps.count ? plan.steps[index].target : nil
        index = min(next, plan.steps.count)
        lastProgress = Date()
        currentFrame = nil
        pointingAtMenu = false
        menuOpened = false
        targetMissingSince = nil
        Log.ask.notice("Tutorial: step \(self.index + 1, privacy: .public) of \(self.plan.steps.count, privacy: .public) (\(reason, privacy: .public))")
        clickedStepAt = reason == "clicked" ? Date() : nil
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
        // The last step was a menu item without "…": by macOS convention it acts at once
        // ("Show All History"), so the task is done — no 5 s "anything left?" call. Items
        // with "…" open a dialog that still needs a click, so those are checked.
        let lastIndex = plan.steps.count - 1
        if let clicked = lastClicked, lastIndex >= 0,
           clicked.role == "AXMenuItem" || menuPaths[lastIndex] != nil,
           !clicked.target.hasSuffix("…"), !clicked.target.hasSuffix("...") {
            Log.ask.notice("Tutorial: the last step was a menu item that acts at once; finished")
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
        // The last step was a dialog's button and the dialog is gone: finished, no need to
        // ask (a menu item as the last step usually opens a dialog: the model plans on).
        if let clicked = lastClicked, clicked.role == "AXButton" {
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let display = Self.displayUnderMouse()
            let now = await Task.detached(priority: .userInitiated) {
                AXInspector.visibleElements(frontmostPID: pid, display: display)
            }.value
            guard isActive else { return }
            if !now.isEmpty, StepMatcher.find(clicked.target, in: now, minimum: 0.95) == nil {
                Log.ask.notice("Tutorial: the last step's button and its dialog are gone; finished")
                finish()
                return
            }
        }
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
        let done = plan.steps.map { step in step.app.map { "\(step.instruction) (in \($0))" } ?? step.instruction }
            .joined(separator: "; ")
        let here = NSWorkspace.shared.frontmostApplication?.localizedName
        let question = """
            \(goal)
            Already done: \(done).
            Now in \(here ?? "the app on screen"). What are the remaining clicks, in this app or others? \
            If it's finished, reply with no steps.
            """
        var next = AskRequest(question: question, screenshotJPEG: encoded.jpeg, screenshotWidth: encoded.width,
                              screenshotHeight: encoded.height, context: context,
                              elements: PromptElement.list(elements, geometry: geometry, question: goal, limit: 25))
        next.planTutorial = true
        next.browser = AppLocator.defaultBrowserName()
        let menus = await Task.detached(priority: .userInitiated) { AXInspector.menuOutline(frontmostPID: pid) }.value
        next.menuOutline = MenuOutline.relevant(menus, to: goal, limit: 25)
        // From text when Accessibility describes the screen (~1 s), else the screenshot.
        var reply: String?
        if TutorialPlanning.canUseTextOnly(elements: next.elements.count, menuItems: menus.count) {
            var textOnly = next
            textOnly.screenshotJPEG = Data()
            reply = await Self.reply(from: provider, to: textOnly, within: .seconds(15))
        }
        if reply == nil, isActive { reply = await Self.reply(from: provider, to: next, within: .seconds(25)) }
        guard isActive else { return }  // stopped meanwhile: stay stopped
        guard let reply, let more = TutorialPlan.parse(reply)?.expandingMenus(using: menus)
            .separatingSetup(frontmostApp: here, isInstalledApp: isInstalledApp), !more.steps.isEmpty else {
            finish()
            return
        }
        guard let rest = TutorialPlan.remaining(more, after: plan.steps) else {
            Log.ask.notice("Tutorial: the follow-up plan starts over; treating the task as done")
            finish()
            return
        }
        continuations += 1
        let room = TutorialPlan.maxSteps - plan.steps.count
        plan.steps += rest.prefix(room)
        lastProgress = Date()
        menuSearched = []
        Log.ask.notice("Tutorial: planned \(min(rest.count, room), privacy: .public) more step(s)")
        onChecklist?(checklistText)
        if speakSteps { speak?(plan.steps[index].instruction) }
    }

    /// Green between lavender steps: open the step's app, then plan this app's part from
    /// what's really there (the steps were guesses made in another app).
    private func switchApp(to app: String, using openApp: (String) async -> Bool) async {
        let segmentEnd = plan.steps[index...].firstIndex { $0.app?.lowercased() != app.lowercased() } ?? plan.steps.count
        Log.ask.notice("Tutorial: step \(self.index + 1, privacy: .public) is in another app; switching")
        overlay.setTutoring(false)
        currentFrame = nil
        let opened = await openApp(app)
        guard isActive else { return }
        guard opened else {
            stop(message: "I couldn't open \(app), so I stopped the tutorial.")
            return
        }
        try? await Task.sleep(for: .milliseconds(700))  // "opened Notes" stays a moment
        guard isActive else { return }
        overlay.clearAction()
        overlay.setTutoring(true)
        lastProgress = Date()
        menuSearched = []
        menuPaths = [:]
        guard index > 0, let provider else { return }  // the first app's steps were planned there
        overlay.tutorialHint("checking…")
        let part = plan.steps[index..<segmentEnd].map(\.instruction).joined(separator: "; ")
        let done = plan.steps[..<index].map(\.instruction).joined(separator: "; ")
        let question = "\(goal)\nAlready done: \(done).\nNow in \(app): the clicks here for this part: \(part)."
        guard let fresh = await planHere(question, provider: provider)?
            .separatingSetup(frontmostApp: app, isInstalledApp: isInstalledApp),
              isActive else { return }
        let here = fresh.steps.filter { $0.app == nil || $0.app?.lowercased() == app.lowercased() }
        guard !here.isEmpty else { return }
        let room = TutorialPlan.maxSteps - (plan.steps.count - (segmentEnd - index))
        plan.steps.replaceSubrange(index..<segmentEnd, with: here.prefix(max(room, 1)))
        Log.ask.notice("Tutorial: planned \(min(here.count, max(room, 1)), privacy: .public) step(s) in the new app")
        onChecklist?(checklistText)
    }

    /// Plans from the frontmost app's menus and elements (text only, ~1–2 s).
    private func planHere(_ question: String, provider: any LLMProvider) async -> TutorialPlan? {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let display = Self.displayUnderMouse()
        let elements = await Task.detached(priority: .userInitiated) {
            AXInspector.visibleElements(frontmostPID: pid, display: display)
        }.value
        let menus = await Task.detached(priority: .userInitiated) { AXInspector.menuOutline(frontmostPID: pid) }.value
        // No screenshot: the element list is given in points (an "image" the display's size).
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let appKit = screen?.frame ?? .zero
        let geometry = ScreenGeometry(imageWidth: Int(appKit.width), imageHeight: Int(appKit.height),
                                      displayFrame: Rect(x: appKit.minX, y: appKit.minY, width: appKit.width, height: appKit.height),
                                      primaryDisplayHeight: Double(NSScreen.screens.first?.frame.height ?? appKit.height))
        var request = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: Int(display.width),
                                 screenshotHeight: Int(display.height), context: ScreenContext(appName: NSWorkspace.shared.frontmostApplication?.localizedName),
                                 elements: PromptElement.list(elements, geometry: geometry, question: goal, limit: 25))
        request.planTutorial = true
        request.browser = AppLocator.defaultBrowserName()
        request.menuOutline = MenuOutline.relevant(menus, to: goal + " " + question, limit: 25)
        guard let reply = await Self.reply(from: provider, to: request, within: .seconds(15)) else { return nil }
        return TutorialPlan.parse(reply)?.expandingMenus(using: menus)
    }

    /// The typed site is open (youtube.com → www.youtube.com/…), or for search text, any
    /// new page has opened.
    private static func typingDone(_ step: TutorialStep, page: String, before: String?) -> Bool {
        guard let host = URL(string: page)?.host?.lowercased() else { return false }
        if let typed = step.typedHost { return host == typed || host.hasSuffix("." + typed) }
        return before != nil && page != before
    }

    private static func isApp(_ name: String, _ app: NSRunningApplication?) -> Bool {
        app?.localizedName?.caseInsensitiveCompare(name) == .orderedSame
    }

    /// What `onFinished` reports when the task is done (checked by the app delegate).
    static let finishedMessage = "✓ Done!"

    private func finish() {
        guard isActive else { return }  // stopped by the user: never "finish" afterwards
        isActive = false
        loop?.cancel()
        loop = nil
        overlay.tutorialDone("done")
        if speakSteps { speak?("Done!") }
        Log.ask.notice("Tutorial finished")
        onFinished?(Self.finishedMessage)
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

    /// The task can be finished without ClickBait seeing the step's click (the user went
    /// their own way, or the plan was off). When the screen has changed since the last
    /// step and nothing has happened for a few seconds, ask whether it's done.
    private func checkForCompletion() async {
        guard !checking, let changed = screenChangedAt, changed > lastProgress,
              Date().timeIntervalSince(lastProgress) > 5,
              Date().timeIntervalSince(lastModelCheck) > Self.modelCheckInterval else { return }
        await askModel()
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
