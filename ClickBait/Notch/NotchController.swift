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
        /// The volume HUD while it shows: the level (0…1) and whether muted.
        var hud: (level: Double, muted: Bool)?
        var tab: Tab = .home
        var settingsReturnTab: Tab = .home
        enum Tab { case home, ask, shelf, settings }
        /// The bean's mood, read from the companion (set by the app delegate).
        var mood: @MainActor () -> Bean.Mood = { .idle }
        /// The launch hello: the open island shows only the bean, big, among sparkles.
        var greeting = false
        /// A question typed in the ask tab: goes to ClickBait's chat (set by the app delegate).
        var ask: @MainActor (String) -> Void = { _ in }
        /// Typing in the panel (the ask field, the shelf's note): the pointer leaving doesn't fold it.
        var editing = false
        /// How the answering model is doing, read each time the panel opens (set by the app delegate).
        var checkHealth: @MainActor () async -> OllamaProvider.Health? = { nil }
        var health: OllamaProvider.Health?

        /// Typing or in Settings: only Esc, ✕ or a click elsewhere folds it.
        var holdsOpen: Bool { editing || tab == .settings }
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
    private var frameTasks: [UInt32: Task<Void, Never>] = [:]
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
        music.onChange = { [weak self] in self?.musicChanged() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
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
        model.state = after
        if after != .expanded, model.tab == .settings { model.tab = .home }
        if after != .expanded { model.greeting = false; model.editing = false }
        Log.app.debug("Notch: \(String(describing: before), privacy: .public) → \(String(describing: after), privacy: .public)")
        if after == .expanded {
            music.refresh()
            Task { @MainActor [weak self] in
                guard let self else { return }
                model.health = await model.checkHealth()
            }
            watchEscape(true)
        } else if before == .expanded {
            watchEscape(false)
        }
        place()
        pointerChanged()
    }

    private func musicChanged() {
        if music.hasTrack, music.isPlaying {
            pausedTask?.cancel()
            setActivity(true)
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
        guard model.activity != on else { return }
        model.activity = on
        place()
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
        let connectedIDs = Set(screens.compactMap(Self.displayID))
        for displayID in panels.keys.filter({ !connectedIDs.contains($0) }) {
            frameTasks.removeValue(forKey: displayID)?.cancel()
            panels.removeValue(forKey: displayID)?.orderOut(nil)
        }
        for screen in screens {
            guard let displayID = Self.displayID(screen),
                  let notch = Self.notch(on: screen),
                  let frame = NotchPanel.frame(model.state, screen: Self.rect(screen.frame), visible: Self.rect(screen.visibleFrame),
                                               notch: notch, activity: model.activity, hud: model.hud != nil,
                                               shelf: model.tab == .shelf, settings: model.tab == .settings) else {
                // Displays without a physical notch still receive the same centered panel.
                guard let displayID = Self.displayID(screen),
                      let frame = NotchPanel.frame(model.state, screen: Self.rect(screen.frame), visible: Self.rect(screen.visibleFrame),
                                                   notch: nil, activity: model.activity, hud: model.hud != nil,
                                                   shelf: model.tab == .shelf, settings: model.tab == .settings) else { continue }
                positionPanel(frame, notch: nil, displayID: displayID)
                continue
            }
            positionPanel(frame, notch: notch, displayID: displayID)
        }
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func positionPanel(_ frame: Rect, notch: Rect?, displayID: UInt32) {
        let target = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        let panel = panels[displayID] ?? makePanel(target, notch: notch, displayID: displayID)
        panels[displayID] = panel
        panel.takesKeyboard = model.state == .expanded
        if !panel.isVisible { panel.setFrame(target, display: true); panel.orderFrontRegardless() }
        if model.state != .expanded, panel.isKeyWindow { panel.resignKey() }
        frameTasks[displayID]?.cancel()
        let current = panel.frame
        guard current != target else { return }

        // Keep the top edge fixed so it remains attached to the physical notch. The damped
        // oscillation adds one small overshoot on opening/closing without a long, floaty bounce.
        frameTasks[displayID] = Task { @MainActor [weak panel] in
            let duration = 0.42
            let start = ProcessInfo.processInfo.systemUptime
            let top = current.maxY
            while !Task.isCancelled {
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / duration)
                let spring = 1 - exp(-14 * progress * duration) * cos(18 * progress * duration)
                let width = current.width + (target.width - current.width) * spring
                let height = current.height + (target.height - current.height) * spring
                let frame = CGRect(x: target.midX - width / 2, y: top - height, width: width, height: height)
                panel?.setFrame(frame, display: true)
                if progress >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }
            panel?.setFrame(target, display: true)
        }
    }

    private func makePanel(_ frame: CGRect, notch: Rect?, displayID: UInt32) -> Panel {
        let panel = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar, where the notch is; below the dock and the companion (`WindowLayers`).
        panel.level = WindowLayers.notch
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = PullHostingView(rootView: NotchView(
            model: model, notch: notch, music: music, shelf: shelf,
            settings: settings, speech: speech, speaker: speaker, searxng: searxng,
            onDragIn: { [weak self] in self?.dragArrived() },
            onTabChange: { [weak self] tab in
                guard let self else { return }
                if tab == .settings, model.tab != .settings { model.settingsReturnTab = model.tab }
                model.editing = false  // the field it was typing in is gone
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
        let mouse = NSEvent.mouseLocation
        let inside = panels.values.contains { $0.isVisible && $0.frame.insetBy(dx: -6, dy: -6).contains(mouse) }
        guard inside != pointerInside else { return }
        pointerInside = inside
        pointerChanged()
    }

    private func pointerChanged() {
        holdTask?.cancel()
        if pointerInside {
            if model.state == .collapsed { apply(.pointerEntered) }
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

    private func watchEscape(_ on: Bool) {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors.removeAll()
        guard on else { return }
        let escape: (NSEvent) -> Bool = { $0.keyCode == 53 }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if escape(event) { MainActor.assumeIsolated { self?.apply(.escape) } }
        }) { escapeMonitors.append(global) }
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
        let first = model.hud == nil
        model.hud = (next.muted ? 0 : next.volume, next.muted)
        if first { place() }
        hudTask?.cancel()
        hudTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            model.hud = nil
            place()
        }
        return true
    }

    #if DEBUG
    /// `CLICKBAIT_TEST_NOTCH`: opens the panel, then reports its state and layer.
    func debugOpen() -> String {
        apply(.clicked)
        return "state \(model.state), level \(primaryPanel?.level.rawValue ?? -1) (dock \(WindowLayers.dock.rawValue)), displays \(panels.count)"
    }

    func debugClose() { apply(.escape) }

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
        // Every mood, large then at header size, still (no breathing or blink).
        let moods = Bean.Mood.allCases.map { mood in
            VStack(spacing: 6) {
                BeanFace(mood: mood, eyes: Bean.eyePairs(for: mood)[0], size: 64)
                Text(mood.rawValue).font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
            }
        }
        let sheet = VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 22) { ForEach(0..<moods.count, id: \.self) { moods[$0] } }
            HStack(spacing: 22) {
                ForEach(Bean.Mood.allCases, id: \.self) { BeanFace(mood: $0, eyes: Bean.eyePairs(for: $0)[0], size: 26) }
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
