import AppKit
import ClickBaitCore
import SwiftUI

/// The notch panel (`NotchPanel` holds its states, the GIF's sizes and springs; `NotchView`
/// draws it): one small, non-activating window at the notch. Closed it's the notch; while music
/// plays it shows the artwork and a visualizer in its wings; the pointer swells it at once and
/// opens it 0.4 s later (or a click, a two-finger pull down, a file dragged onto it); Escape,
/// its collapse control, or a push up closes it. Leaving does not collapse an open panel. The window grows at once and shrinks only once the closing
/// spring has settled, so it never covers more of the menu bar than the black does. Nothing
/// polls while it's closed. Clean-room: no boring.notch code or assets.
@MainActor
final class NotchController {
    /// Passes two-finger scrolls on to the pull-down gesture before SwiftUI sees them.
    private final class PullHostingView<Content: View>: NSHostingView<Content> {
        var onScroll: ((NSEvent) -> Void)?
        override func scrollWheel(with event: NSEvent) {
            onScroll?(event)
            super.scrollWheel(with: event)
        }
        /// The first click acts (a square, the bean, ✕) even when the panel opened by hovering and
        /// isn't key yet; it used to be spent making the panel key (test drive, 2026-10-24).
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private final class Panel: NSPanel {
        /// Only while open, so the note can be typed into; still never activates ClickBait.
        var takesKeyboard = false
        override var canBecomeKey: Bool { takesKeyboard }
        override var canBecomeMain: Bool { false }
        /// It belongs over the menu bar, at the notch: AppKit would push it down below it.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// The quick note, kept in `AppSettings`.
    @MainActor @Observable
    final class Note {
        var text: String { didSet { save(text) } }
        /// Its text view while the shelf shows (`NoteTextView`): the bullet and checkbox
        /// buttons act on its caret, dictation types into it.
        @ObservationIgnored weak var textView: NoteTextBox?
        /// The note has the cursor: dictation goes into it.
        var isTyping: Bool {
            guard let textView, let window = textView.window else { return false }
            return window.isKeyWindow && window.firstResponder === textView
        }
        @ObservationIgnored private let save: (String) -> Void
        init(text: String, save: @escaping (String) -> Void) {
            self.text = text
            self.save = save
        }
    }

    @MainActor @Observable
    final class Model {
        var state: NotchPanel.State = .hidden
        var notch: Rect?
        /// Music playing: the artwork and visualizer in the wings.
        var activity = false
        /// The HUD while it shows: the level (0…1), whether muted, and whether it's the
        /// brightness sky (else the volume's Pac-Man).
        var hud: (level: Double, muted: Bool, sky: Bool)?
        var tab: Tab = .home
        var settingsReturnTab: Tab = .home
        enum Tab { case home, ask, shelf, settings, mirror, music }
        /// The bean's mood, read from the companion (set by the app delegate).
        var mood: @MainActor () -> Bean.Mood = { .idle }
        /// The launch hello: the open island shows only the bean, big, among sparkles.
        var greeting = false
        /// A question typed in the ask tab: goes to ClickBait's chat (set by the app delegate).
        var ask: @MainActor (String) -> Void = { _ in }
        /// The Ask card's voice button, through the dock's recorder (set by the app delegate):
        /// start (nil, or why not), stop and hear, drop, and the loudness for its waveform.
        var voiceStart: @MainActor () -> String? = { "ClickBait isn't ready." }
        var voiceFinish: @MainActor () async -> Result<String, AskCoordinator.CardVoiceError> = {
            .failure(AskCoordinator.CardVoiceError(message: "ClickBait isn't ready."))
        }
        var voiceCancel: @MainActor () -> Void = {}
        var micLevel: @MainActor () -> Float = { 0 }
        /// Bumped when the Ask card's recording was stopped for it (`onCardRecordingDropped`).
        var voiceDrops = 0
        /// Typing in the panel (the ask field, the shelf's note): the pointer leaving doesn't fold it.
        var editing = false
        /// The worst thing wrong right now (`HealthLadder`), read each time the panel opens (set by the app delegate).
        var checkHealth: @MainActor () async -> HealthLadder.Item? = { nil }
        var health: HealthLadder.Item?
        /// The menu bar's menu, whose every item Settings also offers (set by the app delegate).
        @ObservationIgnored weak var menuBar: StatusBarController?
        /// Settings' Permissions page (set by the app delegate).
        @ObservationIgnored weak var permissions: PermissionsManager?
        /// The page Settings opens on.
        var settingsPage: SettingsPage = .general

        /// The chat, shown in the Ask tab once a question is asked there (set by the app delegate).
        var chat: ChatModel?
        /// A conversation started from the Ask tab: it stays in the notch, which grows to fit it.
        var chatting = false { didSet { if chatting != oldValue { onResize() } } }
        /// Re-fits the window to the shape (set by the controller).
        var onResize: @MainActor () -> Void = {}
        /// The notch folded on its conversation: the app delegate ends it.
        var onChatEnd: @MainActor () -> Void = {}
        /// Showing the Ask tab's conversation.
        var showsChat: Bool { tab == .ask && chatting }
        /// The pointer is near the notch: the folded handle shows.
        var nearNotch = false
        /// The display the notch is open on (peek, open, a HUD); every other display's panel
        /// stays folded (user's ask, 2026-10-24: it opened on both monitors). Nil: one display.
        var activeDisplay: UInt32?
        /// Open and done moving: the open panel's own animations run only then (`notchLive`).
        var settled = false
        /// The ⓘ shortcuts card hangs over the panel.
        var showsKeys = false

        /// Typing, in Settings, the mirror or a conversation: only Esc, ✕ or a click elsewhere folds it.
        /// Open until ✕ or Esc, not folded when the pointer leaves: the shelf too (user's ask,
        /// 2026-10-25), so files can be dragged in and out at leisure.
        var holdsOpen: Bool { editing || tab == .settings || tab == .mirror || tab == .shelf || showsChat }
        let note: Note
        init(note: Note) { self.note = note }
    }

    let model: Model
    private let settings: AppSettings
    private let speech: SpeechModelManager
    private let speaker: Speaker
    private let searxng: SearXNGStatus
    private let music = MusicBridge()
    private let shelf = ShelfStore()
    private var panels: [UInt32: Panel] = [:]
    private var pointerInside = false
    private var holdTask: Task<Void, Never>?
    private var pointerMonitors: [Any] = []
    private var hudTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var frameTasks: [UInt32: Task<Void, Never>] = [:]
    /// Each panel's settled frame: its window is briefly bigger while the shape springs.
    private var targets: [UInt32: CGRect] = [:]
    private var pausedTask: Task<Void, Never>?
    private var pull = PullGesture()
    private var escapeMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    private var primaryPanel: Panel? {
        if let screen = Self.screen, let id = Self.displayID(screen), let panel = panels[id] { return panel }
        return panels.values.first
    }

    init(settings: AppSettings, speech: SpeechModelManager, speaker: Speaker) {
        self.settings = settings
        self.speech = speech
        self.speaker = speaker
        searxng = SearXNGStatus(fetcher: settings.web)
        model = Model(note: Note(text: settings.notchNote, save: { [weak settings] in settings?.notchNote = $0 }))
        music.spotifyArtworkAllowed = { [weak settings] in
            guard let settings else { return false }
            return settings.spotifyArtworkAlways || settings.internet.isOn
        }
        music.youtubeArtworkAllowed = { [weak settings] in
            guard let settings else { return false }
            return settings.youtubeThumbnailsAlways || settings.internet.isOn
        }
        music.onChange = { [weak self] in self?.musicChanged() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
        // Another app in front may reach up beside the notch (`appOwnsTop`).
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
    }

    func start() {
        WindowLayers.check()
        model.onResize = { [weak self] in self?.place() }
        shelf.airDrop.anchor = { [weak self] in self?.primaryPanel }
        ShelfDrop.internetOn = { [weak self] in self?.settings.internet.isOn ?? false }
        watchPointer()
        apply(.enabled(settings.notchPanelEnabled))
        // The screen's real shape can arrive after launch; then the hello.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.place()
            try? await Task.sleep(for: .seconds(0.5))
            self?.greet()
        }
    }

    /// Opens on the hello for `greetTime`, then folds to the peek (unless the pointer is on it).
    private func greet() {
        guard model.state == .collapsed || model.state == .peek else { return }
        model.tab = .home
        model.greeting = true
        apply(.clicked)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.greetTime))
            guard let self, model.greeting else { return }
            model.greeting = false
            if model.state == .expanded, !pointerInside { apply(.escape) }
        }
    }

    static let greetTime = 2.6

    /// Folds right down while the companion points, so the panel never hides what it points at
    /// in the menu bar or the top of a window.
    func makeRoom() {
        if model.state == .expanded || model.state == .peek { apply(.escape) }
    }

    func setEnabled(_ enabled: Bool) {
        settings.notchPanelEnabled = enabled
        apply(.enabled(enabled))
    }

    // MARK: State

    private func apply(_ event: NotchPanel.Event) {
        let before = model.state
        var event = event
        if case .enabled(true) = event, NSScreen.screens.isEmpty { event = .displayAvailable(false) }
        let after = NotchPanel.next(before, on: event)
        guard after != before else { return }
        #if DEBUG
        primaryPanel?.contentView.map { NotchFrameProbe.measure($0, label: "\(before) → \(after)") }
        #endif
        // Opening from folded: on the display the pointer is on; it stays there until it folds.
        if before == .collapsed || before == .hidden { model.activeDisplay = Self.displayUnderPointer() }
        model.state = after
        if after == .peek || after == .expanded { NotificationCenter.default.post(name: .clickBaitNotchShown, object: nil) }  // setup's notch step
        if after != .expanded, [.settings, .mirror, .music].contains(model.tab) { model.tab = .home }  // the camera stops
        if after != .expanded { model.greeting = false; model.editing = false; model.showsKeys = false }
        if after != .expanded, model.chatting { model.chatting = false; model.onChatEnd() }
        Log.app.debug("Notch: \(String(describing: before), privacy: .public) → \(String(describing: after), privacy: .public)")
        model.settled = false
        settleTask?.cancel()
        if after == .expanded {
            // The music check, the model's health and the panel's own animations wait until the
            // shape has finished growing: in the same frames they made opening drop frames.
            settleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self, model.state == .expanded else { return }
                model.settled = true
                music.refresh()
                music.follow(true)
                model.health = await model.checkHealth()
            }
            watchEscape(true)
        } else if before == .expanded {
            music.follow(false)
            watchEscape(false)
            // The open panel stays built (hidden) now: a recording in its Ask card stops with it.
            if model.tab == .ask { model.voiceCancel() }
        }
        place()
        pointerChanged()
    }

    private func musicChanged() {
        // Folded, the notch stays folded, music or not: the wings were dead space (user's rule,
        // 2026-10-25). What's playing shows when the notch is opened.
        if music.hasTrack, music.isPlaying {
            pausedTask?.cancel()
            setActivity(false)
        } else if !music.hasTrack {
            setActivity(false)
        } else {
            // Paused: the wings stay a moment, then tuck away.
            pausedTask?.cancel()
            pausedTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, !music.isPlaying else { return }
                setActivity(false)
            }
        }
    }

    private func setActivity(_ on: Bool) {
        guard wantsActivity != on else { return }
        wantsActivity = on
        place()
    }

    /// Music is playing; the wings show it unless an app's window is in their place.
    private var wantsActivity = false
    /// An app's window is in the strip beside the notch (`appOwnsTop`).
    private var topTaken = false

    /// Another app's window reaches the strip beside the notch (the menu bar hides itself, or
    /// an app is full screen): wings there would cover its content (seen 2026-10-23 over a
    /// chat window's header). Window bounds need no permission.
    private static func appOwnsTop(of screen: NSScreen) -> Bool {
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // The strip in Quartz points (top-left origin of the first screen).
        let inset = screen.safeAreaInsets.top
        let strip = CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY, width: screen.frame.width, height: max(inset, 24))
        let me = ProcessInfo.processInfo.processIdentifier
        return windows.contains { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  window[kCGWindowOwnerPID as String] as? Int32 != me,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { return false }
            return bounds.width > 100 && bounds.intersects(strip.insetBy(dx: 0, dy: 2))
        }
    }

    // MARK: Window

    /// The built-in display (with the notch), else the main one.
    private static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first { CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0 }
            ?? NSScreen.screens.first
    }

    private static func rect(_ frame: CGRect) -> Rect {
        Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    /// While the menu bar is hidden (a full-screen app's desktop) macOS reports no notch at all
    /// — inset 0, no side areas, to every process (measured 2026-10-14) — though the camera
    /// housing is still there; so the notch last seen on this display, at this size, is used.
    private static func notch(on screen: NSScreen) -> Rect? {
        let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        let key = "notch.lastSeen.\(display).\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        if let seen = NotchPanel.notch(screen: rect(screen.frame), topInset: screen.safeAreaInsets.top,
                                       leftArea: screen.auxiliaryTopLeftArea.map(rect), rightArea: screen.auxiliaryTopRightArea.map(rect)) {
            UserDefaults.standard.set([seen.x, seen.y, seen.width, seen.height], forKey: key)
            return seen
        }
        guard let saved = UserDefaults.standard.array(forKey: key) as? [Double], saved.count == 4 else { return nil }
        return Rect(x: saved[0], y: saved[1], width: saved[2], height: saved[3])
    }

    /// The window for where things are now. Growing: at once, then the shape springs out inside
    /// it. Shrinking: the shape springs in first; the window follows once it has settled.
    private func place() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            apply(.displayAvailable(false))
            return
        }
        let primary = Self.screen ?? screens[0]
        model.notch = Self.notch(on: primary)
        // The window list only matters for the music wings (off since 2026-10-25); read on
        // every placement, on the main thread, it froze it up to 249 ms (stall trap).
        topTaken = wantsActivity && Self.appOwnsTop(of: primary)
        let activity = wantsActivity && !topTaken
        if model.activity != activity { model.activity = activity }
        let connectedIDs = Set(screens.compactMap(Self.displayID))
        for displayID in panels.keys.filter({ !connectedIDs.contains($0) }) {
            frameTasks.removeValue(forKey: displayID)?.cancel()
            panels.removeValue(forKey: displayID)?.orderOut(nil)
            targets.removeValue(forKey: displayID)
        }
        for screen in screens {
            // Only the active display opens (or shows a HUD); the others stay folded.
            let here = Self.displayID(screen).map(isActive) ?? true
            let state = here ? model.state : .collapsed
            let hud = here && model.hud != nil
            guard let displayID = Self.displayID(screen),
                  let notch = Self.notch(on: screen),
                  let frame = NotchPanel.frame(state, screen: Self.rect(screen.frame), visible: Self.rect(screen.visibleFrame),
                                               notch: notch, activity: model.activity, hud: hud,
                                               shelf: model.tab == .shelf, settings: model.tab == .settings,
                                               mirror: model.tab == .mirror, chat: model.showsChat) else {
                // Displays without a physical notch still receive the same centered panel.
                guard let displayID = Self.displayID(screen),
                      let frame = NotchPanel.frame(state, screen: Self.rect(screen.frame), visible: Self.rect(screen.visibleFrame),
                                                   notch: nil, activity: model.activity, hud: hud,
                                                   shelf: model.tab == .shelf, settings: model.tab == .settings,
                                                   mirror: model.tab == .mirror, chat: model.showsChat) else { continue }
                positionPanel(frame, notch: nil, displayID: displayID)
                continue
            }
            positionPanel(frame, notch: notch, displayID: displayID)
        }
    }

    /// Folded, with the pointer coming near: the clear window grows to the open size now, so a
    /// click only grows the shape. Resizing it in the motion's first frames dropped 2–4 frames
    /// each open (frame probe, 2026-10-25). Clear pixels let clicks through; `targets` (what
    /// counts as on the notch) stays the folded frame.
    private func makeRoom(_ near: Bool) {
        guard model.state == .collapsed, model.hud == nil else { return }
        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(screen), let panel = panels[displayID], let target = targets[displayID],
                  frameTasks[displayID] == nil || frameTasks[displayID]?.isCancelled == true || !near else { continue }
            var room = target
            if near, let open = NotchPanel.frame(.expanded, screen: Self.rect(screen.frame), visible: Self.rect(screen.visibleFrame),
                                                 notch: Self.notch(on: screen), activity: model.activity, hud: false,
                                                 shelf: model.tab == .shelf, settings: model.tab == .settings,
                                                 mirror: model.tab == .mirror, chat: model.showsChat) {
                let width = max(open.width, target.width) * 1.12, height = max(open.height, target.height) * 1.12
                room = CGRect(x: target.midX - width / 2, y: target.maxY - height, width: width, height: height)
            }
            if panel.frame != room { panel.setFrame(room, display: false) }
        }
    }

    /// Whether this display is the one the notch is open on (always, while folded).
    private func isActive(_ displayID: UInt32) -> Bool {
        model.state == .collapsed && model.hud == nil || model.activeDisplay == nil || model.activeDisplay == displayID
    }

    /// The display under the pointer, else the notch's own.
    private static func displayUnderPointer() -> UInt32? {
        let mouse = NSEvent.mouseLocation
        return (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screen).flatMap(displayID)
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func positionPanel(_ frame: Rect, notch: Rect?, displayID: UInt32) {
        let target = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        let panel = panels[displayID] ?? makePanel(target, notch: notch, displayID: displayID)
        panels[displayID] = panel
        panel.takesKeyboard = model.state == .expanded
        // macOS can drop `.canJoinAllSpaces` when a window is reordered, stranding it on one
        // Space; set it again on every placement (adapted from Sentient OS, AGPL-3.0).
        panel.collectionBehavior = Self.collectionBehavior
        if !panel.isVisible { panel.setFrame(target, display: true); panel.orderFrontRegardless() }
        if model.state != .expanded, panel.isKeyWindow { panel.resignKey() }
        // Folded, the island is only a small see-through handle (`NotchView`), so it stays
        // visible everywhere (it used to fade out where its black block covered a page).
        let alpha: CGFloat = 1
        if panel.alphaValue != alpha {
            NSAnimationContext.runAnimationGroup { $0.duration = alpha == 0 ? 0.3 : 0.15; panel.animator().alphaValue = alpha }
        }
        frameTasks[displayID]?.cancel()
        targets[displayID] = target
        let current = panel.frame
        guard current != target else { return }

        // SwiftUI springs the black shape (`Look.Motion`); the clear window only has to hold
        // it. Stepping the window's frame every 16 ms on its own curve re-laid out the whole
        // view each step and fought SwiftUI's spring: choppy. So the window jumps once to
        // fit both sizes plus the spring's overshoot, top edge fixed, and settles on the new
        // size after the motion ends. Clear pixels let clicks through meanwhile.
        let overshoot = 0.12
        let width = max(current.width, target.width) + abs(target.width - current.width) * overshoot
        let height = max(current.height, target.height) + abs(target.height - current.height) * overshoot
        let room = CGRect(x: target.midX - width / 2, y: target.maxY - height, width: width, height: height)
        if room != current { panel.setFrame(room, display: true) }
        frameTasks[displayID] = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(Self.motionSettles))
            guard !Task.isCancelled, let self else { return }
            frameTasks[displayID] = nil
            if model.state == .collapsed && model.nearNotch { makeRoom(true) } else { panel?.setFrame(target, display: true) }
        }
    }

    #if DEBUG
    /// Debug only: how smooth a notch motion was. Every frame's gap for 0.8 s after a state
    /// change; logs the count, the slowest and how many took over 20 ms ("Notch motion:").
    @MainActor final class NotchFrameProbe: NSObject {
        private static var current: NotchFrameProbe?
        private var link: CADisplayLink?
        private var last: CFTimeInterval?
        private var gaps: [CFTimeInterval] = []
        private var start: CFTimeInterval = 0
        private let label: String

        private init(label: String) { self.label = label }

        static func measure(_ view: NSView, label: String) {
            current?.finish()
            let probe = NotchFrameProbe(label: label)
            let link = view.displayLink(target: probe, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            probe.link = link
            probe.start = CACurrentMediaTime()
            current = probe
        }

        @objc private func tick(_ link: CADisplayLink) {
            let now = link.timestamp
            if let last { gaps.append(now - last) }
            last = now
            if now - start > 0.8 { finish() }
        }

        private func finish() {
            link?.invalidate()
            link = nil
            guard !gaps.isEmpty else { return }
            let slow = gaps.filter { $0 > 0.02 }.count
            let at = gaps.indices.filter { gaps[$0] > 0.02 }.map { "#\($0):\(Int(gaps[$0] * 1000))" }.joined(separator: " ")
            let worst = Int((gaps.max() ?? 0) * 1000)
            Log.app.notice("Notch motion \(self.label, privacy: .public): \(self.gaps.count, privacy: .public) frames, \(slow, privacy: .public) over 20 ms, slowest \(worst, privacy: .public) ms (\(at, privacy: .public))")
            if Self.current === self { Self.current = nil }
        }
    }
    #endif

    /// Long enough for the open spring and the close curve to come to rest.
    private static let motionSettles = 0.8

    private static let collectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

    private func makePanel(_ frame: CGRect, notch: Rect?, displayID: UInt32) -> Panel {
        let panel = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar, where the notch is; below the dock and the companion (`WindowLayers`).
        panel.level = WindowLayers.notch
        panel.collectionBehavior = Self.collectionBehavior
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = PullHostingView(rootView: NotchView(
            model: model, displayID: displayID, notch: notch, music: music, shelf: shelf,
            settings: settings, speech: speech, speaker: speaker, searxng: searxng,
            onDragIn: { [weak self] in self?.dragArrived() },
            onTabChange: { [weak self] tab in
                guard let self else { return }
                if tab == .settings, model.tab != .settings { model.settingsReturnTab = model.tab }
                model.editing = false  // the field it was typing in is gone
                // Leaving Ask with a chat open ends that chat (it isn't kept out of sight).
                if model.chatting, tab != .ask { model.chatting = false; model.onChatEnd() }
                model.tab = tab
                self.place()
            },
            onCollapse: { [weak self] in self?.apply(.escape) }))
        host.onScroll = { [weak self] in self?.scrolled($0) }
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    // MARK: Pointer and keys

    /// The pointer, read from every mouse move (a non-activating panel gets no hover events
    /// while another app is in front): coming onto the notch slides it out (peek, then open
    /// after `openDwell`; a click opens at once). Leaving folds it back after `leaveHold`.
    /// On and off use `NotchPanel.pointerOn`'s hysteresis.
    private func watchPointer() {
        let moved: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.pointerMoved() } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moved) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            moved(event)
            return event
        }) { pointerMonitors.append(local) }
        if let click = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window is Panel else { return }
                self.model.greeting = false
                guard self.model.state == .collapsed || self.model.state == .peek else { return }
                self.apply(.clicked)
            }
            return event
        }) { pointerMonitors.append(click) }
    }

    private func pointerMoved() {
        guard model.state != .hidden else { return }
        let mouse = NSEvent.mouseLocation, point = Point(x: mouse.x, y: mouse.y)
        // Folded: any display's handle can be opened. Peeking or open: only its own display counts,
        // so the other monitor's handle neither keeps it open nor opens a second one.
        let active = model.state == .collapsed ? nil : model.activeDisplay
        let inside = panels.contains { displayID, panel in
            (active == nil || displayID == active) && panel.isVisible
                && NotchPanel.pointerOn(point, frame: Self.rect(targets[displayID] ?? panel.frame), wasOn: pointerInside)
        }
        // Near the notch (80 pt around it, at the top): the folded handle shows; otherwise it
        // stays out of sight (user's ask, 2026-10-24).
        let near = panels.contains { displayID, panel in
            panel.isVisible && (targets[displayID] ?? panel.frame).insetBy(dx: -80, dy: -60).contains(mouse)
        }
        if model.nearNotch != near {
            model.nearNotch = near
            makeRoom(near)
        }
        guard inside != pointerInside else { return }
        pointerInside = inside
        pointerChanged()
    }

    private func pointerChanged() {
        holdTask?.cancel()
        if pointerInside {
            if model.state == .collapsed {
                apply(.pointerEntered)
                // A light tick on the trackpad as it slides out (adapted from Sentient OS, AGPL-3.0).
                if model.state == .peek { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
            guard model.state == .peek else { return }
            holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(NotchPanel.openDwell))
                guard !Task.isCancelled, let self, pointerInside else { return }
                apply(.pointerStayed)
            }
            return
        }
        guard model.state == .expanded || model.state == .peek, !model.holdsOpen, !model.greeting else { return }
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NotchPanel.leaveHold))
            guard !Task.isCancelled else { return }
            self?.apply(.pointerLeft)
        }
    }

    /// Two fingers on the trackpad over the notch: down opens, up closes (`PullGesture`).
    private func scrolled(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return }  // a mouse wheel isn't a pull
        let ended = event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .began
        if let pulled = pull.add(deltaY: Double(event.scrollingDeltaY), inverted: event.isDirectionInvertedFromDevice, ended: ended) {
            apply(pulled)
        }
    }

    /// A file dragged onto the closed notch: open on the shelf, ready to drop.
    private func dragArrived() {
        model.tab = .shelf
        if model.state != .expanded { apply(.clicked) }
    }

    /// Esc pressed in any app (from `InputInterceptor`, which already sees every key): closes
    /// the open panel, with no global key monitor of its own (adapted from Sentient OS, AGPL-3.0).
    func escapePressed() {
        if model.state == .expanded { apply(.escape) }
    }

    /// Esc while the panel itself has the keyboard: taken here so the field doesn't beep.
    private func watchEscape(_ on: Bool) {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors.removeAll()
        guard on else { return }
        let escape: (NSEvent) -> Bool = { $0.keyCode == 53 }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard escape(event) else { return event }
            MainActor.assumeIsolated { self?.apply(.escape) }
            return nil
        }) { escapeMonitors.append(local) }
    }

    // MARK: Volume HUD

    /// A volume key (from `InputInterceptor`): set the volume ourselves and show the HUD in the
    /// notch's wings. False — the key goes to macOS untouched — when the HUD is off, the panel is
    /// hidden or open, there's no notch, or the device won't take it.
    func handleVolumeKey(_ key: VolumeStep.Key, fine: Bool) -> Bool {
        guard settings.notchVolumeHUD, model.state == .collapsed || model.state == .peek, let screen = Self.screen,
              Self.notch(on: screen) != nil, let now = SystemVolume.read() else { return false }
        let next = VolumeStep.apply(key, volume: now.volume, muted: now.muted, fine: fine)
        guard SystemVolume.write(volume: next.volume, muted: next.muted) else { return false }
        showHUD((next.muted ? 0 : next.volume, next.muted, false))
        return true
    }

    /// A brightness key: the built-in screen's brightness set here, the sky's time of day shown
    /// in the wings. False (the key goes to macOS) in the same cases as the volume's, or when
    /// the brightness can't be read or set (`SystemBrightness`).
    func handleBrightnessKey(_ key: VolumeStep.Key, fine: Bool) -> Bool {
        guard settings.notchBrightnessHUD, model.state == .collapsed || model.state == .peek, let screen = Self.screen,
              Self.notch(on: screen) != nil, let now = SystemBrightness.read() else { return false }
        let next = BrightnessStep.apply(key, level: now, fine: fine)
        guard SystemBrightness.write(next) else { return false }
        showHUD((next, false, true))
        return true
    }

    private func showHUD(_ hud: (level: Double, muted: Bool, sky: Bool)) {
        if model.hud == nil { model.activeDisplay = Self.displayUnderPointer() }
        let first = model.hud == nil || model.hud?.sky != hud.sky
        model.hud = hud
        if first { place() }
        hudTask?.cancel()
        hudTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            model.hud = nil
            place()
        }
    }

    #if DEBUG
    /// `CLICKBAIT_TEST_NOTCH`: opens the panel, then reports its state and layer.
    func debugOpen() -> String {
        apply(.clicked)
        return "state \(model.state), level \(primaryPanel?.level.rawValue ?? -1) (dock \(WindowLayers.dock.rawValue)), displays \(panels.count)"
    }

    func debugClose() { apply(.escape) }

    /// For the test driver: the notch panel's frame (AppKit points), if it's showing.
    var debugPanelFrame: CGRect? { primaryPanel.map { $0.frame } }

    /// For the test driver: every display's notch panel frame.
    var debugPanelFrames: [CGRect] { panels.values.map(\.frame) }

    var debugFrame: String { "\(primaryPanel?.frame ?? .zero), visible \(primaryPanel?.isVisible ?? false), displays \(panels.count)" }

    /// The pointer coming onto the notch: it peeks at once; leaving starts the fold.
    func debugHover() async -> String {
        let before = primaryPanel?.frame.width ?? 0
        pointerInside = true
        pointerChanged()
        try? await Task.sleep(for: .seconds(0.1))
        let peek = model.state == .peek, width = primaryPanel?.frame.width ?? 0
        try? await Task.sleep(for: .seconds(0.5))
        let opened = model.state == .expanded
        pointerInside = false
        pointerChanged()
        try? await Task.sleep(for: .seconds(0.6))
        return "width \(before) → peek \(peek) at \(width), then open \(opened), then folded \(model.state == .collapsed), displays \(panels.count)"
    }

    /// Renders the open panel and the closed music wings to `folder` (the screen can't be
    /// captured here).
    /// The panel as it draws in `state` on `tab`, hosted in an offscreen window (never shown) so
    /// AppKit-backed views — the shelf's note, the file drag handle — draw too, unlike
    /// `ImageRenderer`. For the UI smoke tests (ClickBaitTests) and `debugRender`.
    func snapshot(_ state: NotchPanel.State, tab: Model.Tab = .home, greeting: Bool = false,
                  activity: Bool = false, chat: ChatModel? = nil, keys: Bool = false,
                  hud: (level: Double, muted: Bool)? = nil, sky: Double? = nil) -> NSBitmapImageRep? {
        let hud = sky.map { (level: $0, muted: false, sky: true) } ?? hud.map { (level: $0.level, muted: $0.muted, sky: false) }
        let saved = (model.state, model.tab, model.greeting, model.activity, model.chat, model.chatting, model.onResize, model.showsKeys, model.hud)
        defer { (model.state, model.tab, model.greeting, model.activity, model.chat, model.chatting, model.onResize, model.showsKeys, model.hud) = saved }
        model.onResize = {}  // a render: the real window stays as it is
        (model.state, model.tab, model.greeting, model.activity, model.showsKeys, model.hud) = (state, tab, greeting, activity, keys, hud)
        if let chat { (model.chat, model.chatting) = (chat, true) }
        let look = NotchPanel.shape(state, notch: model.notch, activity: activity, hud: hud != nil,
                                    shelf: tab == .shelf, settings: tab == .settings, chat: model.showsChat)
        let size = NSSize(width: look.width + 2 * NotchPanel.ear + 60, height: look.height + 30)
        let host = NSHostingView(rootView: NotchView(
            model: model, notch: model.notch, music: music, shelf: shelf,
            settings: settings, speech: speech, speaker: speaker, searxng: searxng,
            onDragIn: {}, onTabChange: { _ in }, onCollapse: {})
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.12, green: 0.16, blue: 0.22)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host.sharpRep()
    }

    func debugRender(to folder: String) {
        let cover = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.15, green: 0.3, blue: 0.85, alpha: 1), NSColor(red: 0.85, green: 0.7, blue: 0.4, alpha: 1)])?
                .draw(in: rect, angle: -40)
            return true
        }
        music.debugFake(title: "Green Light", artist: "Lorde", duration: 234, position: 177, artwork: cover)
        for (name, state, activity) in [("notch-open", NotchPanel.State.expanded, true), ("notch-wings", .collapsed, true),
                                        ("notch-peek", .peek, true), ("notch-greeting", .expanded, true), ("notch-empty", .expanded, false)] {
            model.greeting = name == "notch-greeting"
            let saved = (model.state, model.activity)
            model.state = state
            model.activity = activity
            if !activity { music.debugClear() }
            let look = NotchPanel.shape(state, notch: model.notch, activity: activity, hud: false)
            let view = NotchView(model: model, notch: model.notch, music: music, shelf: shelf,
                settings: settings, speech: speech, speaker: speaker,
                searxng: searxng,
                onDragIn: {}, onTabChange: { _ in }, onCollapse: {})
                .frame(width: look.width + 2 * NotchPanel.ear + 60, height: look.height + 30)
                .background(Color(red: 0.12, green: 0.16, blue: 0.22))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
            }
            (model.state, model.activity) = saved
        }
        // Every mood with each of its eye pairs, large, then at header size; still (no breathing or blink).
        let moods = Bean.Mood.allCases.map { mood in
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(Bean.eyePairs(for: mood), id: \.self) { BeanFace(mood: mood, eyes: $0, size: 64) }
                }
                Text(mood.rawValue).font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
            }
        }
        let sheet = VStack(alignment: .leading, spacing: 20) {
            ForEach(0..<3, id: \.self) { row in
                HStack(alignment: .top, spacing: 22) { ForEach(Array(moods.indices).filter { $0 % 3 == row }, id: \.self) { moods[$0] } }
            }
            HStack(spacing: 22) {
                ForEach(Bean.Mood.allCases, id: \.self) { BeanFace(mood: $0, eyes: Bean.eyePairs(for: $0)[0], size: 26) }
            }
            // The Mirror pill's chrome bean through its shimmer, large then at pill size.
            HStack(spacing: 22) {
                ForEach([0.0, 0.8, 1.6, 2.4], id: \.self) {
                    BeanFace(mood: .idle, eyes: .both(.dot), size: 64, badge: false, solid: true, holo: true, sheen: $0)
                }
                BeanFace(mood: .idle, eyes: .both(.dot), size: 22, badge: false, solid: true, holo: true, sheen: 1.2)
            }
        }
        .padding(24)
        .background(Color.black)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: folder).appending(path: "notch-bean.png"))
        }
    }

    /// `CLICKBAIT_TEST_NOTCH_HUD`: one volume-up through the HUD, then the volume put back exactly.
    func debugHUD() -> String {
        guard let before = SystemVolume.read() else { return "no output device volume" }
        let taken = handleVolumeKey(.up, fine: false)
        let after = SystemVolume.read()
        _ = SystemVolume.write(volume: before.volume, muted: before.muted)
        return "taken \(taken), volume \(before.volume) → \(after?.volume ?? -1), restored \(SystemVolume.read().map { abs($0.volume - before.volume) < 0.001 } ?? false)"
    }
    #endif
}

extension NSView {
    /// The view drawn at `scale` × its points: offscreen windows draw at 1× otherwise, which
    /// looks soft once the picture is shown anywhere bigger than its points (renders, the site).
    func sharpRep(scale: CGFloat = 3) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        return rep
    }
}
