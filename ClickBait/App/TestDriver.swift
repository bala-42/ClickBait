#if DEBUG
import AppKit
import ApplicationServices
import ClickBaitCore

/// Debug only: ClickBait tries itself out, as a person would. It finds its own buttons through
/// Accessibility, clicks and drags with real system events, presses the brightness and volume
/// keys, types questions into its chat, follows walkthroughs by clicking where the companion
/// points, and takes screenshots. Each check logs ✓ or ✗ ("Drive:") and the run writes
/// `report.md` beside its screenshots.
///
/// `open -n --env CLICKBAIT_TEST_DRIVE=all --env CLICKBAIT_TEST_DRIVE_OUT=<folder> ClickBait.app`
/// (or a comma list: handle,tabs,bean,keys,voice,dock,stutter,walkthroughs,safari).
///
/// Safe by design: it never clicks a step that destroys something (`destructive`): it stops
/// there and presses Esc. It puts back what it changes: brightness, volume, Finder's path bar,
/// the private window it opens.
@MainActor
final class TestDriver {
    struct Hooks {
        let notch: NotchController
        let coordinator: AskCoordinator
        let overlay: OverlayController
        let tutorial: TutorialController
        let backgroundJobs: BackgroundJobs
        let chat: ChatController
        let capsules: CapsuleController
        let goThere: (UUID) -> Void
    }

    private let hooks: Hooks
    private let out: URL
    private var lines: [String] = []
    private var failures = 0

    /// Steps a walkthrough must never click: they delete, quit or shut down.
    static let destructive = ["clear history", "empty bin", "empty trash", "force quit", "delete", "erase", "shut down",
                              "restart", "log out", "remove", "reset"]

    init(hooks: Hooks, out: URL) {
        self.hooks = hooks
        self.out = out
    }

    static func runIfRequested(_ hooks: @escaping () -> Hooks) {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["CLICKBAIT_TEST_DRIVE"] else { return }
        let folder = URL(fileURLWithPath: env["CLICKBAIT_TEST_DRIVE_OUT"] ?? NSTemporaryDirectory() + "ClickBaitDrive")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let all = ["handle", "displays", "tabs", "bean", "keys", "voice", "stutter", "dock", "walkthroughs", "pointing", "safari"]
        let wanted = spec == "all" ? all : spec.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))  // the speech model and the notch settle
            let driver = TestDriver(hooks: hooks(), out: folder)
            await driver.run(wanted)
        }
    }

    func run(_ names: [String]) async {
        note("# ClickBait test drive, \(Date().formatted(date: .abbreviated, time: .shortened))")
        for name in names {
            note("\n## \(name)")
            switch name {
            case "handle": await handle()
            case "displays": await displays()
            case "tabs": await tabs()
            case "bean": await bean()
            case "keys": await keys()
            case "voice": await voice()
            case "stutter": await stutter()
            case "dock": await dock()
            case "walkthroughs": await walkthroughs()
            case "pointing": await pointing("where is control center")
            case "world": await world()
            case "writing": await writing()
            case "downloads": await chromeDownloads()
            case "mictest": await microphoneTest()
            case "safari": await safari()
            default: note("(unknown check \(name))")
            }
        }
        note("\n**\(failures == 0 ? "All checks passed" : "\(failures) check(s) failed").**")
        try? lines.joined(separator: "\n").write(to: out.appending(path: "report.md"), atomically: true, encoding: .utf8)
        Log.app.notice("Drive: done, \(self.failures, privacy: .public) failed; report in \(self.out.path, privacy: .public)")
    }

    // MARK: - Checks

    /// The folded notch's handle shows near the notch and hides away from it.
    private func handle() async {
        guard let panel = hooks.notch.debugPanelFrame, let screen = NSScreen.main else { return check(false, "notch panel found") }
        hooks.notch.debugClose()
        move(to: quartz(CGPoint(x: screen.frame.midX, y: screen.frame.midY)))
        let hidden = await wait(2) { !self.hooks.notch.model.nearNotch }
        check(hidden, "away from the notch: handle hidden")
        move(to: quartz(CGPoint(x: panel.midX, y: screen.frame.maxY - 70)))
        let shown = await wait(2) { self.hooks.notch.model.nearNotch }
        check(shown, "near the notch: handle shown")
        await shot("handle-near")
        move(to: quartz(CGPoint(x: screen.frame.midX, y: screen.frame.midY)))
    }

    /// With two displays, the notch opens on the one it was opened on; the other stays folded.
    private func displays() async {
        guard NSScreen.screens.count > 1 else { return note("- (one display: skipped)") }
        guard await openByHand() else { return check(false, "notch opens by pointing and clicking") }
        try? await Task.sleep(for: .milliseconds(700))
        let frames = hooks.notch.debugPanelFrames
        let open = frames.filter { $0.width >= 600 }.count
        check(frames.count > 1 && open == 1, "open on one display only (\(frames.map { Int($0.width) }) pt wide)")
        await shot("displays-open")
        hooks.notch.debugClose()
    }

    /// Each square opens its tab (its bean flies to the corner) and ✕ goes back home.
    private func tabs() async {
        guard await openByHand() else { return check(false, "notch opens by pointing and clicking") }
        // Ask and Shelf (Music's square is named after what's playing).
        for (label, tab) in [("Ask", NotchController.Model.Tab.ask), ("Shelf", .shelf)] {
            guard let button = await element(label) else {
                check(false, "\(label) square found")
                continue
            }
            await click(at: centre(button))
            try? await Task.sleep(for: .milliseconds(140))
            await shot("tab-\(label)-flying")
            let opened = await wait(2) { self.hooks.notch.model.tab == tab }
            check(opened, "\(label) square opens its tab")
            try? await Task.sleep(for: .milliseconds(500))
            await shot("tab-\(label)")
            // The panel springs to the tab's size first: let it settle, then find ✕ where it is now.
            try? await Task.sleep(for: .milliseconds(500))
            if let back = await element("Back to Home") { await click(at: centre(back)) }
            var home = await wait(2) { self.hooks.notch.model.tab == .home }
            if !home, let back = await element("Back to Home") {
                note("  - ✕ didn't take on the first click; clicked again")
                await click(at: centre(back))
                home = await wait(2) { self.hooks.notch.model.tab == .home }
            }
            check(home, "✕ in \(label) goes back home")
            try? await Task.sleep(for: .milliseconds(400))
        }
        hooks.notch.debugClose()
    }

    /// The space bean: grabbed, pulled, let go, it springs back home.
    private func bean() async {
        guard await openByHand() else { return check(false, "notch opens by pointing and clicking") }
        try? await Task.sleep(for: .milliseconds(600))
        // Where the bean is laid out (its accessibility frame is reported at the wrong place):
        // the space card's middle, 171 pt in and 91 pt down the 640 pt panel, centred on screen.
        guard let panel = hooks.notch.debugPanelFrame else { return check(false, "notch panel found") }
        let start = quartz(CGPoint(x: panel.midX - NotchPanel.expandedSize.width / 2 + 171, y: panel.maxY - 91))
        let play = SpaceToyPlay.shared
        move(to: CGPoint(x: start.x - 5, y: start.y))
        try? await Task.sleep(for: .milliseconds(60))
        move(to: start)
        try? await Task.sleep(for: .milliseconds(200))
        note("  - before the press: notch \(hooks.notch.model.state), tab \(hooks.notch.model.tab), pointer at \(Int(start.x)),\(Int(start.y)), panel \(panel)")
        await shot("bean-before")
        mouse(.leftMouseDown, at: start)
        try? await Task.sleep(for: .milliseconds(60))
        var held = false
        for step in 1...12 {
            mouse(.leftMouseDragged, at: CGPoint(x: start.x + CGFloat(step) * 9, y: start.y + CGFloat(step) * 1.5))
            try? await Task.sleep(for: .milliseconds(16))
            held = held || play.toy.held
        }
        await shot("bean-pulled")
        let pulled = play.toy.offset.x
        mouse(.leftMouseUp, at: CGPoint(x: start.x + 108, y: start.y + 18))
        check(held && pulled > 20, "grabbed and pulled (\(Int(pulled)) pt)")
        let home = await wait(4) { !play.toy.isMoving }
        check(home && play.toy.offset == Point(x: 0, y: 0), "let go, it springs back home")
        hooks.notch.debugClose()
    }

    /// Brightness keys show the sky; volume keys Pac-Man. Both put back afterwards.
    private func keys() async {
        hooks.notch.debugClose()
        if let screen = NSScreen.main { move(to: quartz(CGPoint(x: screen.frame.midX, y: screen.frame.midY))) }  // away from the notch
        try? await Task.sleep(for: .milliseconds(800))
        // Through the handler the key catcher calls: macOS keeps keys an app posts itself from
        // that app's own catcher, so the real keypress is the user's to try.
        if let before = SystemBrightness.read() {
            _ = hooks.notch.handleBrightnessKey(before < 0.9 ? .up : .down, fine: false)
            let sky = await wait(1.5) { self.hooks.notch.model.hud?.sky == true }
            let after = SystemBrightness.read() ?? before
            check(sky && abs(after - before) > 0.01,
                  "brightness key: sky shown, \(Int(before * 100))% → \(Int(after * 100))% (notch \(hooks.notch.model.state))")
            await shot("brightness-sky")
            _ = SystemBrightness.write(before)
        } else {
            check(false, "brightness readable")
        }
        try? await Task.sleep(for: .seconds(1.8))
        if let before = SystemVolume.read() {
            _ = hooks.notch.handleVolumeKey(before.volume < 0.9 ? .up : .down, fine: false)
            let shown = await wait(1.5) { self.hooks.notch.model.hud != nil && self.hooks.notch.model.hud?.sky == false }
            check(shown, "volume key: Pac-Man shown")
            await shot("volume-pacman")
            _ = SystemVolume.write(volume: before.volume, muted: before.muted)
        }
    }

    /// The Ask card's voice: start, stop, Esc, dictation taking over.
    private func voice() async {
        let model = hooks.notch.model
        let started = model.voiceStart()
        check(started == nil && hooks.coordinator.isCardRecording, "voice starts (\(started ?? "ok"))")
        try? await Task.sleep(for: .seconds(1))
        if case .failure(let error) = await model.voiceFinish() { check(false, "stop: \(error.message)") } else { check(true, "stop gives a result") }
        _ = model.voiceStart()
        key(53)  // Esc
        let stopped = await wait(1) { !self.hooks.coordinator.isCardRecording }
        check(stopped, "Esc stops a recording")
    }

    /// The companion following a moving pointer: stalls over 20 s of circling.
    private func stutter() async {
        guard let screen = NSScreen.main else { return }
        let before = hooks.overlay.debugStalls
        let centre = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        let start = Date()
        var angle = 0.0
        while Date().timeIntervalSince(start) < 20 {
            angle += 0.05
            move(to: quartz(CGPoint(x: centre.x + 220 * cos(angle), y: centre.y + 140 * sin(angle))))
            try? await Task.sleep(for: .milliseconds(16))
        }
        let stalls = hooks.overlay.debugStalls - before
        check(stalls <= 10, "20 s of following: \(stalls) stall(s) (a hitch over 80 ms each)")
    }

    /// A slow question goes to the dock within about a second.
    private func dock() async {
        activate("com.apple.finder")
        let before = hooks.backgroundJobs.entries.count
        ask("write a snake game in python")  // code answers go to the dock once they take a second
        let docked = await wait(8) { self.hooks.backgroundJobs.entries.count > before }
        check(docked, "a slow answer goes to the dock")
        await shot("dock")
    }

    /// Walkthroughs in Finder and from the menu bar, followed by clicking where it points.
    private func walkthroughs() async {
        activate("com.apple.finder")
        await walkthrough("how do I show the status bar in finder", name: "finder-status-bar")
        // Asked again, it's already on: it should say so and finish.
        await walkthrough("how do I show the status bar in finder", name: "finder-already-on")
        activate("com.apple.finder")
        try? await Task.sleep(for: .milliseconds(400))
        key(44, flags: .maskCommand)  // ⌘/: the status bar back off, as it was
    }

    /// Safari, restarted so ClickBait can learn its menus: a private window (closed after) and
    /// clearing history up to, never through, the button that clears it.
    private func safari() async {
        let id = "com.apple.Safari"
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { app.terminate() }
        _ = await wait(10) { NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        try? await Task.sleep(for: .seconds(4))
        let menus = MenuMemory.outline(pid: NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier)
        check(!menus.isEmpty, "Safari's menus readable after a restart (\(menus.count) items)")
        await walkthrough("how do I open a private window in safari", name: "safari-private")
        key(13, flags: .maskCommand)  // ⌘W: the private window it opened
        try? await Task.sleep(for: .seconds(1))
        activate(id)
        await walkthrough("how do I clear my history in safari", name: "safari-history")
    }

    // MARK: - Walkthroughs

    private func walkthrough(_ question: String, name: String) async {
        let stallsBefore = hooks.overlay.debugStalls
        let jobsBefore = Set(hooks.backgroundJobs.entries.map(\.id))
        ask(question)
        // Planned in the dock, then "show me!".
        let ready = await wait(60) {
            self.hooks.backgroundJobs.entries.contains { entry in
                guard !jobsBefore.contains(entry.id), entry.walkthrough != nil, case .done = entry.job.status else { return false }
                return true
            }
        }
        guard ready, let job = hooks.backgroundJobs.entries.first(where: { !jobsBefore.contains($0.id) && $0.walkthrough != nil }) else {
            return check(false, "\"\(question)\": planned in the dock")
        }
        check(true, "\"\(question)\": planned in the dock")
        hooks.goThere(job.id)
        guard await wait(30, { self.hooks.tutorial.isActive }) else { return check(false, "show me! starts it") }
        var clicked = 0
        var lastIndex = -1
        while hooks.tutorial.isActive {
            let step = hooks.tutorial.debugStep
            guard await wait(12, { self.hooks.tutorial.debugStep.target != nil || !self.hooks.tutorial.isActive }) else {
                check(false, "step \(step.index + 1) (\(step.label ?? "?")): nothing pointed at")
                await shot("\(name)-stuck")
                key(53)
                break
            }
            guard hooks.tutorial.isActive, let target = hooks.tutorial.debugStep.target else { break }
            let label = hooks.tutorial.debugStep.label ?? ""
            if Self.destructive.contains(where: { label.lowercased().contains($0) && !label.hasSuffix("…") }) {
                check(true, "reached \"\(label)\" and stopped (never clicked)")
                await shot("\(name)-final")
                key(53)  // Esc: the walkthrough and the dialog
                try? await Task.sleep(for: .milliseconds(400))
                key(53)
                return
            }
            lastIndex = hooks.tutorial.debugStep.index
            await shot("\(name)-step\(lastIndex + 1)")
            try? await Task.sleep(for: .milliseconds(900))  // let it settle on the target, as a person would
            // Where it points now: the first target can be a guess it corrects (it once clicked 91 pt off).
            let settled = hooks.tutorial.debugStep.target ?? target
            await click(at: CGPoint(x: settled.x + settled.width / 2, y: settled.y + settled.height / 2))
            clicked += 1
            _ = await wait(8) { self.hooks.tutorial.debugStep.index != lastIndex || !self.hooks.tutorial.isActive }
            if clicked > 8 { break }
        }
        let stalls = hooks.overlay.debugStalls - stallsBefore
        check(!hooks.tutorial.isActive && clicked > 0, "\"\(question)\": finished after \(clicked) click(s), \(stalls) stall(s)")
    }

    /// A general-knowledge question gets an answer, not "can't tell you" (user's Steve Jobs
    /// question, 2026-10-24), with Notes or whatever's in front on screen.
    private func world() async {
        let start = Date()
        ask("hey, can you tell me who Steve Jobs is?")
        let answered = await wait(40) {
            !self.hooks.coordinator.isBusy && self.hooks.chat.model.messages.last?.role == .assistant
                && !(self.hooks.chat.model.messages.last?.text.isEmpty ?? true)
        }
        let reply = hooks.chat.model.messages.last(where: { $0.role == .assistant })?.text ?? ""
        note("  - reply after \(Int(Date().timeIntervalSince(start))) s: \"\(reply.prefix(160))\"")
        check(answered && reply.localizedCaseInsensitiveContains("apple"), "\"who is Steve Jobs\" is answered (mentions Apple)")
    }

    /// Settings' "Test microphone" runs without crashing (its audio tap once ran main-actor
    /// code on the audio thread, 2026-10-25) and hears the room.
    private func microphoneTest() async {
        let test = MicrophoneTest()
        test.start()
        var heard: Float = 0
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            heard = max(heard, test.level)
        }
        let running = test.isRunning
        test.stop()
        check(running && test.failure == nil, "microphone test runs 2 s without crashing (loudest \(String(format: "%.2f", heard)))")
    }

    /// "Show me my downloads" with Chrome in front: Chrome's own steps (it once planned Finder's
    /// and looked for Finder's Go menu in Chrome, 2026-10-25). Closes the tab it opens.
    private func chromeDownloads() async {
        activate("com.google.Chrome")
        try? await Task.sleep(for: .milliseconds(800))
        await walkthrough("how do I see my downloads", name: "chrome-downloads")
        try? await Task.sleep(for: .milliseconds(800))
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" { key(13, flags: .maskCommand) }  // ⌘W
    }

    /// fn+⌃ writing's model step: point form from a paragraph, and a reply from an email on
    /// screen (the spoken part needs a voice; this checks what's written).
    private func writing() async {
        let paragraph = "We met on Tuesday to plan the launch. Priya will finish the landing page by Friday, Sam is "
            + "booking the photographer, and we agreed to send the newsletter on the 3rd."
        let points = await hooks.coordinator.writeDictation("give it to me in point form", subject: paragraph, screen: nil, app: "Notes")
        let lines = points?.split(separator: "\n").filter { $0.hasPrefix("•") } ?? []
        note("  - point form: \"\((points ?? "").prefix(220))\"")
        check(lines.count >= 2 && points?.contains("Priya") == true, "\"give it to me in point form\" gives points, keeping the facts")
        let email = "From: Blu Revolution\nI was one of the first to try ClickBait, a fun week project. Thanks for the update!"
        let reply = await hooks.coordinator.writeDictation("reply to this email, thank them and ask what they use it for",
                                                           subject: nil, screen: email, app: "Mail")
        note("  - reply: \"\((reply ?? "").prefix(260))\"")
        check((reply?.count ?? 0) > 40 && reply?.lowercased().contains("thank") == true, "\"reply to this email\" writes a reply")
    }

    /// A "where is" question points at the thing (no walkthrough).
    private func pointing(_ question: String) async {
        ask(question)
        let guided = await wait(20) { self.hooks.overlay.isGuiding }
        check(guided, "\"\(question)\": points")
        try? await Task.sleep(for: .seconds(1))
        await shot("pointing")
    }

    // MARK: - Doing things

    /// Opens the notch as a person does: points at it, lets it peek, clicks.
    private func openByHand() async -> Bool {
        hooks.notch.debugClose()
        try? await Task.sleep(for: .milliseconds(400))
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return false }
        let top = quartz(CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 12))
        move(to: CGPoint(x: top.x, y: top.y + 60))
        try? await Task.sleep(for: .milliseconds(150))
        move(to: top)
        _ = await wait(1.5) { self.hooks.notch.model.state != .collapsed }
        await click(at: top)
        return await wait(2) { self.hooks.notch.model.state == .expanded }
    }

    private func ask(_ question: String) {
        note("  - asking \"\(question)\" (chat busy before: \(hooks.chat.model.isBusy), ClickBait busy: \(hooks.coordinator.isBusy))")
        hooks.coordinator.startTypedChat(trigger: "test drive")
        hooks.chat.model.draft = question
        hooks.chat.model.send()
    }

    private func activate(_ bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
    }

    private func move(to point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func mouse(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// As a person clicks: the pointer arrives, rests a moment, presses, releases.
    private func click(at point: CGPoint) async {
        move(to: CGPoint(x: point.x - 6, y: point.y - 4))
        try? await Task.sleep(for: .milliseconds(60))
        move(to: point)
        try? await Task.sleep(for: .milliseconds(180))
        mouse(.leftMouseDown, at: point)
        try? await Task.sleep(for: .milliseconds(70))
        mouse(.leftMouseUp, at: point)
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Looking

    /// Waits until `condition` holds, checking every 50 ms; false after `seconds`.
    private func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// One of ClickBait's own controls by its accessibility label, in Quartz points. On the main
    /// thread: asked from inside the app, Accessibility answers on the asking thread, and off the
    /// main thread that opened the menu-bar menu there (a crash, 2026-10-24).
    private func element(_ label: String, prefix: Bool = false) async -> CGRect? {
        Self.find(label, prefix: prefix, pid: getpid())
    }

    private static func find(_ label: String, prefix: Bool, pid: pid_t) -> CGRect? {
        func string(_ element: AXUIElement, _ name: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? String
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            var position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success else { return nil }
            var point = CGPoint.zero, extent = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &point)
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
            return CGRect(origin: point, size: extent)
        }
        var stack = [AXUIElementCreateApplication(pid)]
        var visited = 0
        while let element = stack.popLast(), visited < 5_000 {
            visited += 1
            // Never into menus: looking at one opens it.
            if let role = string(element, kAXRoleAttribute), ["AXMenuBar", "AXMenu", "AXMenuBarItem", "AXMenuItem"].contains(role) {
                continue
            }
            for name in [kAXDescriptionAttribute, kAXTitleAttribute] {
                if let text = string(element, name), prefix ? text.hasPrefix(label) : text == label, let rect = frame(element), rect.width > 0 {
                    return rect
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                stack.append(contentsOf: list)
            }
        }
        return nil
    }

    private func centre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// AppKit (y up from the main screen's bottom) → Quartz (y down from its top).
    private func quartz(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    }

    private func shot(_ name: String) async {
        guard let capture = try? await ScreenCapturer().captureDisplayUnderCursor(excluding: AppBlocklist(apps: []), ignoreClickBait: false),
              let data = NSBitmapImageRep(cgImage: capture.image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: out.appending(path: "\(name).png"))
        lines.append("  - screenshot: \(name).png")
    }

    private func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        note("- \(ok ? "✓" : "✗") \(what)")
        Log.app.notice("Drive: \(ok ? "✓" : "✗", privacy: .public) \(what, privacy: .public)")
    }

    private func note(_ line: String) { lines.append(line) }
}
#endif
