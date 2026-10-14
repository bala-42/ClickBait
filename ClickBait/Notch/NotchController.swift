import AppKit
import ClickBaitCore
import SwiftUI

/// The notch panel (`NotchPanel` holds its states and layout): one small, non-activating
/// window over the notch. Collapsed it's notch-sized and black, so it disappears into the
/// notch, with a small tab beside it when an agent is working or done; resting the pointer on
/// it (or a click) opens the widgets, and moving away, a click or Escape closes them. Nothing
/// samples or polls while it's closed. On a display without a notch it's a small pill under
/// the menu bar. Clean-room: no boring.notch code or assets.
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
        /// Only open, so the note can be typed into; still never activates ClickBait.
        var takesKeyboard = false
        override var canBecomeKey: Bool { takesKeyboard }
        override var canBecomeMain: Bool { false }
        /// It belongs over the menu bar, at the notch: AppKit would push it down below it.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    @MainActor @Observable
    final class Model {
        var state: NotchPanel.State = .hidden
        var tabDot: AgentDock.Dot?
        var hasNotch = true
        var notchWidth: CGFloat = 0
        var widgets: [any NotchWidget] = []
        /// The companion's model: the panel glows in its state colour.
        var companion: OverlayModel?
        /// Home (music, events), Shelf (files, note) or Mirror (the camera).
        var tab: Tab = .home
        enum Tab { case home, shelf, mirror }
        /// The volume HUD while it shows: the level (0…1) and whether muted.
        var hud: (level: Double, muted: Bool)?
    }

    let model = Model()
    private let settings: AppSettings
    private let jobs: BackgroundJobs
    private var panel: Panel?
    private var hoverTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var pull = PullGesture()
    private var escapeMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private let allWidgets: [any NotchWidget]

    init(settings: AppSettings, jobs: BackgroundJobs, companion: OverlayModel) {
        model.companion = companion
        self.settings = settings
        self.jobs = jobs
        allWidgets = [ClockWidget(), StatsWidget(), BatteryWidget(), ModesWidget(settings: settings),
                      MusicWidget(), CalendarWidget(), MirrorWidget(),
                      ShelfWidget(), NoteWidget(settings: settings)]
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place(animated: false) }
        }
    }

    func start() {
        WindowLayers.check()
        apply(.enabled(settings.notchPanelEnabled))
        // The screen's real shape can arrive after launch; and a full-screen desktop has none.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.place(animated: false)
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place(animated: false) }
        }
    }

    #if DEBUG
    /// `CLICKBAIT_TEST_NOTCH=1`: opens the panel, then reports its frame and layer.
    func debugOpen() -> String {
        apply(.clicked)
        return "state \(model.state), frame \(panel?.frame ?? .zero), level \(panel?.level.rawValue ?? -1) (dock \(WindowLayers.dock.rawValue)), widgets \(model.widgets.map(\.id))"
    }

    func debugClose() { apply(.escape) }

    /// Renders the open panel to `folder`/notch.png (the screen can't be captured here).
    func debugRender(to folder: String) {
        let size = NotchPanel.expandedSize
        let view = NotchView(model: model, onHover: { _ in }, onTap: {}, onDragIn: {})
            .frame(width: size.width, height: size.height)
            .padding(30).background(Color(white: 0.75))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: folder).appending(path: "notch.png"))
        }
    }

    /// `CLICKBAIT_TEST_NOTCH_HUD`: one volume-up through the HUD, its wings rendered, then the
    /// volume put back exactly.
    func debugHUD(render folder: String?) -> String {
        guard let before = SystemVolume.read() else { return "no output device volume" }
        let taken = handleVolumeKey(.up, fine: false)
        let after = SystemVolume.read()
        let report = "taken \(taken), volume \(before.volume) → \(after?.volume ?? -1), hud \(model.hud != nil), frame \(panel?.frame ?? .zero)"
        if let folder {
            let size = CGSize(width: 185 + 2 * NotchPanel.hudWing, height: 32)
            let view = NotchView(model: model, onHover: { _ in }, onTap: {}, onDragIn: {})
                .frame(width: size.width, height: size.height).padding(20).background(Color(white: 0.75))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: folder).appending(path: "hud.png"))
            }
        }
        _ = SystemVolume.write(volume: before.volume, muted: before.muted)
        return report + ", restored \(SystemVolume.read().map { abs($0.volume - before.volume) < 0.001 } ?? false)"
    }

    var debugFrame: String { "\(panel?.frame ?? .zero), visible \(panel?.isVisible ?? false)" }
    #endif

    func setEnabled(_ enabled: Bool) {
        settings.notchPanelEnabled = enabled
        apply(.enabled(enabled))
    }

    /// A volume key (from `InputInterceptor`): set the volume ourselves and show the HUD in
    /// the notch. False — the key goes to macOS untouched — when the HUD is off, the panel is
    /// hidden or open, there's no notch, or the device won't take it.
    func handleVolumeKey(_ key: VolumeStep.Key, fine: Bool) -> Bool {
        guard settings.notchVolumeHUD, model.state == .collapsed, let screen = Self.screen,
              Self.notch(on: screen) != nil, let now = SystemVolume.read() else { return false }
        model.hasNotch = true
        let next = VolumeStep.apply(key, volume: now.volume, muted: now.muted, fine: fine)
        guard SystemVolume.write(volume: next.volume, muted: next.muted) else { return false }
        let first = model.hud == nil
        model.hud = (next.muted ? 0 : next.volume, next.muted)
        if first { place(animated: true) }
        hudTask?.cancel()
        hudTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            model.hud = nil
            place(animated: true)
        }
        return true
    }

    /// The dock changed: the collapsed tab shows what's waiting.
    func jobsChanged() {
        let tiles = jobs.entries.map { (CapsulePresentation.status(of: $0.job), $0.seen) }
        let dot: AgentDock.Dot? = tiles.contains { $0.0 == .working || ($0.0 == .done && !$0.1) }
            ? DockCollapse.handleDot(tiles) : nil
        guard dot != model.tabDot else { return }
        model.tabDot = dot
        if model.state == .collapsed { place(animated: true) }
    }

    // MARK: State

    private func apply(_ event: NotchPanel.Event) {
        let before = model.state
        var event = event
        if case .enabled(true) = event, Self.screen == nil { event = .displayAvailable(false) }
        let after = NotchPanel.next(before, on: event)
        guard after != before else { return }
        model.state = after
        Log.app.debug("Notch: \(String(describing: before), privacy: .public) → \(String(describing: after), privacy: .public)")
        if after == .expanded {
            model.widgets = allWidgets.filter(\.isAvailable)
            model.widgets.forEach { $0.expanded() }
            watchEscape(true)
        } else if before == .expanded {
            allWidgets.forEach { $0.collapsed() }
            watchEscape(false)
        }
        place(animated: true)
    }

    // MARK: Window

    /// The display with the notch (the built-in one), else the main display.
    private static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first { CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0 }
            ?? NSScreen.screens.first
    }

    private static func rect(_ frame: CGRect) -> Rect {
        Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    /// Read fresh each time: at launch an agent app can be told there's no notch (inset 0, no
    /// side areas — measured 2026-10-14), and full-screen desktops hide the menu bar.
    /// While the menu bar is hidden (a full-screen app's desktop) macOS reports no notch at all
    /// — inset 0, no side areas (measured 2026-10-14) — though the camera housing is still there.
    /// So the notch last seen on this display, at this size, is remembered (`UserDefaults`, by
    /// display number) and used then.
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

    private func place(animated: Bool) {
        guard let screen = Self.screen else {
            apply(.displayAvailable(false))
            return
        }
        let notch = Self.notch(on: screen)
        model.hasNotch = notch != nil
        Log.app.debug("""
            Notch: screen \(String(describing: screen.frame), privacy: .public) visible \(String(describing: screen.visibleFrame), privacy: .public) \
            inset \(screen.safeAreaInsets.top, privacy: .public) left \(String(describing: screen.auxiliaryTopLeftArea), privacy: .public) \
            → notch \(notch.map { "\($0)" } ?? "none", privacy: .public)
            """)
        model.notchWidth = notch.map { CGFloat($0.width) } ?? 0
        guard let frame = NotchPanel.frame(model.state, screen: Self.rect(screen.frame), visible: Self.rect(screen.visibleFrame),
                                           notch: notch, showsTab: model.tabDot != nil, showsHUD: model.hud != nil) else {
            panel?.orderOut(nil)
            return
        }
        let target = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        let panel = self.panel ?? makePanel(target)
        self.panel = panel
        panel.takesKeyboard = model.state == .expanded
        if !panel.isVisible { panel.setFrame(target, display: true); panel.orderFrontRegardless() }
        guard panel.frame != target else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        if model.state != .expanded, panel.isKeyWindow { panel.resignKey() }
    }

    private func makePanel(_ frame: CGRect) -> Panel {
        let panel = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar, where the notch is; below the dock and the companion (`WindowLayers`).
        panel.level = WindowLayers.notch
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = PullHostingView(rootView: NotchView(model: model, onHover: { [weak self] in self?.hovering($0) },
                                                       onTap: { [weak self] in self?.apply(.clicked) },
                                                       onDragIn: { [weak self] in self?.dragArrived() }))
        host.onScroll = { [weak self] in self?.scrolled($0) }
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// Two fingers on the trackpad over the notch: down opens, up closes (`PullGesture`).
    private func scrolled(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return }  // a mouse wheel isn't a pull
        let ended = event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .began
        if let pulled = pull.add(deltaY: Double(event.scrollingDeltaY), inverted: event.isDirectionInvertedFromDevice, ended: ended) {
            hoverTask?.cancel()
            apply(pulled)
        }
    }

    /// A file dragged onto the closed notch: open on the shelf, ready to drop.
    private func dragArrived() {
        model.tab = .shelf
        if model.state == .collapsed { apply(.clicked) }
    }

    // MARK: Pointer and keys

    /// Resting on it for `hoverDelay` opens it; away for `leaveDelay` closes it. A pass over
    /// the notch on the way to the menu bar does neither.
    private func hovering(_ inside: Bool) {
        hoverTask?.cancel()
        let delay = inside ? NotchPanel.hoverDelay : NotchPanel.leaveDelay
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.apply(inside ? .hoverDwelled : .pointerLeft)
        }
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
}

/// The notch's outline: flush with the top, its upper corners flaring out into the menu bar
/// (`ear`, curving the other way, as the notch's own do), its lower corners rounded.
struct NotchShape: InsettableShape {
    var ear: CGFloat
    var bottom: CGFloat
    var inset: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func inset(by amount: CGFloat) -> NotchShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let e = min(ear, r.width / 4), b = min(bottom, (r.height) / 2, (r.width - 2 * e) / 2)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        // The left ear: a quarter curve from the top edge in to the body's side.
        path.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.minY + e), control: CGPoint(x: r.minX + e, y: r.minY))
        path.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - b))
        path.addQuadCurve(to: CGPoint(x: r.minX + e + b, y: r.maxY), control: CGPoint(x: r.minX + e, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX - e - b, y: r.maxY))
        path.addQuadCurve(to: CGPoint(x: r.maxX - e, y: r.maxY - b), control: CGPoint(x: r.maxX - e, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - e, y: r.minY))
        path.closeSubpath()
        return path
    }
}

/// Black like the notch, so it grows out of it. Collapsed: empty over the notch, a dot in the
/// tab when something waits. Open: a header row either side of the notch (the time; stats and
/// mode switches) and dark Aqua cards below (music, agents, note).
private struct NotchView: View {
    let model: NotchController.Model
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    let onDragIn: () -> Void

    private static let ear: CGFloat = 10

    var body: some View {
        let open = model.state == .expanded
        let shape = NotchShape(ear: open ? Self.ear : 0, bottom: open ? 24 : 10)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            if open {
                // The chat's dark Aqua body (tint, pinstripes) fading in below the notch, its
                // hairline along the sides and bottom; the top stays black into the notch.
                ZStack {
                    LinearGradient(colors: [AquaDark.tintTop, AquaDark.tintBottom], startPoint: .top, endPoint: .bottom)
                        .opacity(AquaDark.tintOpacity * 2)
                    Image(nsImage: AquaDark.pinstripes).resizable(resizingMode: .tile)
                }
                .clipShape(shape)
                .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3)))
                shape.stroke(AquaDark.border.opacity(0.7), lineWidth: 0.8)
                    .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)))
            }
            if open {
                VStack(spacing: 10) {
                    header
                    HStack(spacing: 8) {
                        ForEach(model.widgets.filter { $0.placement == Self.placement(for: model.tab) }, id: \.id) { widget in
                            widget.view
                        }
                    }
                }
                .padding(.horizontal, Self.ear + 14)
                .padding(.bottom, 14)
                .transition(.opacity)
            } else if let hud = model.hud {
                hudWings(hud)
            } else if let dot = model.tabDot {
                HStack {
                    Spacer()
                    Circle().fill(AgentDockStyle.dot(dot)).frame(width: 7, height: 7)
                        .shadow(color: AgentDockStyle.dot(dot).opacity(0.8), radius: 3)
                        .padding(.trailing, 11)
                }
                .frame(maxHeight: .infinity)
                .accessibilityLabel("Background ClickBaits waiting")
            }
        }
        .contentShape(shape)
        // Dragging a file onto the closed notch opens the shelf (no hover events mid-drag).
        .dropDestination(for: URL.self) { _, _ in false } isTargeted: { if $0, !open { onDragIn() } }
        .onHover(perform: onHover)
        .onTapGesture { if !open { onTap() } }
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.2), value: open)
        .accessibilityElement(children: open ? .contain : .ignore)
        .accessibilityLabel(open ? "ClickBait notch panel" : "ClickBait notch panel, closed. Click to open.")
        .accessibilityAddTraits(open ? [] : .isButton)
    }

    private static func placement(for tab: NotchController.Model.Tab) -> NotchPlacement {
        switch tab {
        case .home: .card
        case .shelf: .shelf
        case .mirror: .mirror
        }
    }

    /// The volume HUD in the notch's wings: the speaker left of the notch, the level right of
    /// it as a light-blue Aqua gel bar in a recessed well.
    private func hudWings(_ hud: (level: Double, muted: Bool)) -> some View {
        let symbol = hud.muted ? "speaker.slash.fill" : hud.level < 0.34 ? "speaker.wave.1.fill"
            : hud.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        return HStack(spacing: 0) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(AquaDark.textPrimary)
                .frame(width: NotchPanel.hudWing)
            Spacer(minLength: 0)
            ZStack(alignment: .leading) {
                AquaWell(shape: Capsule(), darkness: 0.5, bordered: true)
                AquaGel(palette: .lightBlue, shape: Capsule()).frame(width: max(8, 64 * hud.level))
            }
            .frame(width: 64, height: 8)
            .frame(width: NotchPanel.hudWing)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hud.muted ? "Volume muted" : "Volume \(Int((hud.level * 100).rounded())) percent")
    }

    /// Home, Shelf and Mirror, as small gel buttons (light blue: the one showing).
    private var tabs: some View {
        HStack(spacing: 4) {
            tabButton(.home, symbol: "house.fill", label: "Home")
            tabButton(.shelf, symbol: "tray.full.fill", label: "Shelf")
            tabButton(.mirror, symbol: "camera.fill", label: "Mirror")
        }
    }

    private func tabButton(_ tab: NotchController.Model.Tab, symbol: String, label: String) -> some View {
        NotchGelButton(on: model.tab == tab, size: CGSize(width: 24, height: 18),
                       action: { model.tab = tab }) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
    }

    /// Beside the notch (it stays black in the middle): the leading widgets left of it, the
    /// trailing ones right of it. Without a notch, one row across.
    private var header: some View {
        HStack(spacing: 10) {
            ForEach(model.widgets.filter { $0.placement == .headerLeading && $0.id == "clock" }, id: \.id) { $0.view }
            tabs
            ForEach(model.widgets.filter { $0.placement == .headerLeading && $0.id != "clock" }, id: \.id) { $0.view }
            Spacer(minLength: model.hasNotch ? model.notchWidth + 12 : 12)
            ForEach(model.widgets.filter { $0.placement == .headerTrailing }, id: \.id) { $0.view }
        }
        .frame(height: model.hasNotch ? 32 : 26)
        .padding(.top, model.hasNotch ? 0 : 6)
    }
}
