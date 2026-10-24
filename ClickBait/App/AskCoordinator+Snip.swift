import AppKit
import AVFoundation
import ClickBaitCore
import Observation

// The element list and snips (hold ⌥⌘).
extension AskCoordinator {
    // MARK: - Element list

    /// Every listed element costs the local model prompt time (100 took answers to
    /// 11–16 s); the question's matches and open menus are listed first.
    static let maxListedElements = 40

    /// What Accessibility says is clickable on the captured display (off the main thread).
    static func elements(in capture: ScreenCapture, frontmostPID pid: pid_t?) async -> [ScreenElement] {
        let frame = capture.displayFrame
        let display = Rect(x: frame.minX, y: capture.primaryDisplayHeight - frame.maxY, width: frame.width, height: frame.height)
        let start = ContinuousClock.now
        let mouse = NSEvent.mouseLocation
        let pointer = Point(x: mouse.x, y: capture.primaryDisplayHeight - mouse.y)
        let elements = await Task.detached(priority: .userInitiated) { () -> [ScreenElement] in
            let front = AXInspector.visibleElements(frontmostPID: pid, display: display)
            guard front.isEmpty, let under = AXInspector.appPID(at: pointer), under != pid else { return front }
            // The app in front has nothing on this display: read the one under the cursor.
            return AXInspector.visibleElements(frontmostPID: under, display: display)
        }.value
        let menus = elements.filter { $0.role == "AXMenuItem" }.count
        Log.ask.notice("""
            Element list: \(elements.count, privacy: .public) clickable (\(menus, privacy: .public) menu items) in \
            \(String(describing: ContinuousClock.now - start), privacy: .public)
            """)
        return elements
    }

    // MARK: - Snip (hold ⌥⌘)


    func snip(_ kind: SnipKind, region: Rect, path: [Point]) {
        stopRefining()
        tutorial?.stop(message: nil)
        guard state != .listening, state != .thinking, !isAnswering else { return }
        onSnipAnswering?(true)  // after the guard: a refused snip leaves no red behind
        onInvoked?()  // the chat pops out of the companion where the circling ended
        speaker.stop()
        if conversation != nil {
            closeChat()
            onChatClose?()
        }
        errorResetTask?.cancel()

        let frontmost = NSWorkspace.shared.frontmostApplication
        guard checkCanAsk(frontmost: frontmost) else { return }
        frontmostPID = frontmost?.processIdentifier
        frontmostBundleID = frontmost?.bundleIdentifier
        context = ScreenContext(appName: frontmost?.localizedName)
        let provider = settings.makeProvider()
        self.provider = provider
        Task.detached(priority: .userInitiated) { await provider.warmUp() }
        // Orange (and sendable) from the closed circle: its picture isn't a question yet, but
        // a peel waits for the explanation to start.
        let flow = QuestionFlow(work: .snip, phase: .buildingRequest)
        flow.provider = provider
        // Home is the window under the middle of what was circled (it can be another app's
        // than the front one, or on another display), so "go there!" returns to it.
        let underPID = AXInspector.appWithWindow(at: Point(x: region.x + region.width / 2, y: region.y + region.height / 2))
        if let underPID, underPID != frontmostPID, let app = NSRunningApplication(processIdentifier: underPID) {
            frontmostPID = underPID
            frontmostBundleID = app.bundleIdentifier
            context = ScreenContext(appName: app.localizedName)
            Log.ask.notice("Snip home: the app under the circle, not the front one")
        }
        flow.context = context
        flow.homeBundleID = frontmostBundleID
        flow.homePID = frontmostPID
        currentFlow = flow
        state = .thinking
        Log.ask.notice("Snip: \(kind.rawValue, privacy: .public) \(Int(region.width), privacy: .public)×\(Int(region.height), privacy: .public) pt")
        askTask = Task { await finishSnip(kind, region: region, path: path, flow: flow) }
    }

    func finishSnip(_ kind: SnipKind, region: Rect, path: [Point], flow: QuestionFlow) async {
        defer { end(flow) }
        let startedAt = ContinuousClock.now
        // Marked files in Finder become the selection, so "combine these" acts on them.
        if flow.homeBundleID == FileAction.requiredFrontmostApp, let pid = flow.homePID {
            await selectMarkedFiles(kind: kind, region: region, path: path, finderPID: pid)
        }
        // The display holding the middle of the region.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = NSPoint(x: region.x + region.width / 2, y: primaryHeight - (region.y + region.height / 2))
        let capture: ScreenCapture
        do {
            capture = try await capturer.captureDisplayUnderCursor(excluding: settings.blocklist, at: center,
                                                                   ignoreClickBait: settings.ignoreNotchInCaptures)
        } catch {
            Log.capture.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            report("Couldn't capture the screen: \(error.localizedDescription)", for: flow)
            return
        }
        guard !Task.isCancelled else { return }
        // The window's title tells the model what app/document the marked thing is in.
        let pid = flow.homePID
        let snapshot = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid) }.value
        flow.context.windowTitle = snapshot.windowTitle
        flow.context.windowFrame = snapshot.windowFrame
        // The window under the circle, not just the app's focused one: from accessibility,
        // which lists only real windows (the window list has a browser's helper windows too).
        let middle = Point(x: region.x + region.width / 2, y: region.y + region.height / 2)
        if let pid, let under = await Task.detached(priority: .userInitiated, operation: { AXInspector.window(at: middle, pid: pid) }).value {
            flow.context.windowTitle = under.title ?? snapshot.windowTitle
            flow.context.windowFrame = under.frame
            readBrowserTab(for: flow, at: middle)
            Log.ask.notice("Snip home: the window under the circle (\(under.title == nil ? "untitled" : "titled", privacy: .public))")
        } else {
            Log.ask.notice("Snip home: no window under the circle; the app's focused one")
        }
        if currentFlow === flow { context = flow.context }
        let view: SnipView
        do {
            view = try SnipRenderer.view(capture, region: region)
        } catch {
            report("Couldn't read that part of the screen.", for: flow)
            return
        }
        let encoding = Task.detached(priority: .userInitiated) { try ScreenshotEncoder.encode(view.image) }
        // Printed labels, read on this Mac while the model answers (for the parts tour).
        if flow.jobID == nil {  // sent away: the foreground's memory is the next question's
            snipMemory?.text?.cancel()
            snipMemory?.objects?.cancel()
            snipMemory?.reference?.cancel()
        }
        let text = Task { await TextReader.read(view.image) }
        let objects = Self.findObjects(in: view)
        flow.pendingSnipView = (view, text, objects)
        // The words inside what was marked, for the model as exact text: from the app, and read off
        // the close-up (a small circle on a 1× display came out too soft to read, 2026-10-25).
        flow.snipMarked = view.marked
        let appWords = await Task.detached(priority: .userInitiated) { AXInspector.texts(in: region, pid: pid) }.value
        let read = await TextReader.read(text, within: .milliseconds(600))
            .filter { view.marked.minX...view.marked.maxX ~= $0.center.x && view.marked.minY...view.marked.maxY ~= $0.center.y }
            .map(\.text).joined(separator: " ")
        let words = [appWords, read].filter { !$0.isEmpty }.joined(separator: " · ")
        flow.snipWords = words.isEmpty ? nil : words
        Log.ask.notice("Snip words: \(appWords.count, privacy: .public) characters from the app, \(read.count, privacy: .public) read off the close-up")
        // No whole-screen context picture: with qwen2.5vl:7b it doubled the wait (8–13 s)
        // and made answers worse; the window title gives the context instead.
        let contextImage: Data? = nil
        await withTaskCancellationHandler {
            await respond(question: "", selectedText: nil, capture: capture, encoding: encoding, startedAt: startedAt,
                          speak: false, display: kind == .circled ? "Explain what I circled" : "Explain what I boxed",
                          snip: kind, snipContext: contextImage, flow: flow)
        } onCancel: {
            text.cancel()
            objects.cancel()
        }
    }

    func selectMarkedFiles(kind: SnipKind, region: Rect, path: [Point], finderPID pid: pid_t) async {
        let points = SnipArea.samples(kind: kind, region: region, path: path)
        let urls = await Task.detached(priority: .userInitiated) {
            AXInspector.finderItemURLs(at: points, finderPID: pid)
        }.value
        Log.ask.notice("Snip in Finder: \(urls.count, privacy: .public) file(s) under the marked area")
        guard !urls.isEmpty else { return }
        do {
            let selected = try await FinderSelection.select(urls)
            Log.ask.notice("Snip in Finder: selected \(selected, privacy: .public) of \(urls.count, privacy: .public)")
        } catch {
            Log.ask.error("Snip in Finder: couldn't select the marked files: \(error.localizedDescription, privacy: .public)")
        }
    }
}
