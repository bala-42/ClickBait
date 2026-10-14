import AppKit
import ClickBaitCore
import SwiftUI

/// The background dock (`AgentDock`): one small window per tile, top-right of the menu-bar
/// display, newest on top, and a second small window for a tile's card while it's open.
/// Small windows only: screen-sized ones on every desktop blacken Mission Control.
/// Left alone, the dock folds away to a slim handle at the screen's edge (`DockCollapse`), so
/// it covers nothing; a click on the handle, or a shake over it, brings it back.
@MainActor
final class CapsuleController {
    var onGoThere: ((UUID) -> Void)?
    var onStop: ((UUID) -> Void)?
    var onLater: ((UUID) -> Void)?
    var onDismiss: ((UUID) -> Void)?
    var onSeen: ((UUID) -> Void)?
    var onSuggestion: ((UUID, String) -> Void)?
    /// The done card's mini-chat: ask in the dock (nil, or why not), and the card's own microphone.
    var onFollowUpSend: ((UUID, String) -> String?)?
    var onCardVoiceStart: (() -> String?)?
    var onCardVoiceCancel: (() -> Void)?
    var onCardVoiceFinish: (() async -> Result<String, AskCoordinator.CardVoiceError>)?
    var cardMicrophoneLevel: (() -> Float)?
    var canGoThere: (() -> Bool)?

    /// Room around a tile and a card for their glows inside their windows.
    static let tileMargin: CGFloat = 12
    static let cardMargin: CGFloat = 22

    private final class Panel: NSPanel {
        /// Only a card with its text panel open takes the keyboard (a non-activating panel:
        /// the app in front stays active); everything else never does.
        var takesKeyboard = false
        override var canBecomeKey: Bool { takesKeyboard }
        override var canBecomeMain: Bool { false }
        /// Fading out as the dock folds: shown again, it fades back from where it is.
        var folding = false
    }

    /// A click on a tile or card works at once, without first activating ClickBait.
    private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// The card's window is made the first time it opens: most tiles are never opened, and
    /// each window costs main-thread time to create.
    private final class Managed {
        let presentation: CapsulePresentation
        let tile: Panel
        var card: Panel?
        var cardHost: NSHostingView<CapsuleView>?

        init(presentation: CapsulePresentation, tile: Panel) {
            self.presentation = presentation
            self.tile = tile
        }

        var panels: [Panel] { [tile] + (card.map { [$0] } ?? []) }
    }

    private var managed: [UUID: Managed] = [:]
    private var clickMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var latestEntries: [BackgroundJobs.Entry] = []

    // MARK: Folding (`DockCollapse`)
    /// The tiles are hidden and only the handle shows.
    private(set) var isCollapsed = false
    /// Bumped on every fold and unfold: a fade that ends after the next one began leaves its
    /// window alone (rapid toggling).
    private var foldGeneration = 0
    private var handle: Panel?
    private let handleModel = DockHandleModel()
    private var idleTimer: Timer?
    private var lastAttended = ContinuousClock.now
    private var moveMonitors: [Any] = []
    private var shake = ShakeDetector()

    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redock() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.collapseOutside(NSEvent.mouseLocation) }
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let point = event.window?.convertPoint(toScreen: event.locationInWindow) { self?.collapseOutside(point) }
            }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    func sync(_ entries: [BackgroundJobs.Entry]) {
        let arrived = entries.contains { managed[$0.id] == nil }
        latestEntries = entries
        let ids = Set(entries.map(\.id))
        for id in Array(managed.keys) where !ids.contains(id) {
            guard let item = managed.removeValue(forKey: id) else { continue }
            for panel in item.panels where panel.isVisible {
                panel.ignoresMouseEvents = true
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().setFrame(panel.frame.offsetBy(dx: 12, dy: 0), display: true)
                    panel.animator().alphaValue = 0
                } completionHandler: {
                    // AppKit runs this on the main thread, but doesn't say so to Swift.
                    MainActor.assumeIsolated {
                        panel.orderOut(nil)
                        panel.close()
                    }
                }
            }
        }
        for entry in entries {
            if let item = managed[entry.id] {
                // Only what changed: each streamed word would otherwise redraw every tile.
                if !item.presentation.entry.looksSame(as: entry) { item.presentation.entry = entry }
            } else {
                managed[entry.id] = makeManaged(entry)
            }
        }
        if entries.isEmpty {
            unfoldQuietly()
        } else if arrived, isCollapsed {
            summon()  // a peel is flying into the top slot: the dock must be there to catch it
            return
        } else if arrived {
            lastAttended = .now
        }
        redock()
        updateIdleTimer()
    }

    /// The centre of slot `index`'s tile, where a peel flies to.
    func slotCenter(forIndex index: Int) -> CGPoint? {
        guard let screen = mainScreen, let tile = AgentDock.tile(index, in: Self.rect(screen.visibleFrame)) else { return nil }
        return CGPoint(x: tile.midX, y: tile.midY)
    }

    /// [later, pls]: folds the card; the tile stays.
    func fold(_ id: UUID) {
        guard let item = managed[id] else { return }
        item.presentation.isExpanded = false
        redock()
    }

    func expand(_ id: UUID) {
        guard let item = managed[id] else {
            Log.app.error("Background tile recall target was missing")
            return
        }
        Log.app.notice("Background tile expanded from menu")
        if isCollapsed { summon() }
        open(item)
    }

    /// Brings the folded dock back: the tiles fade in where they were, ready to click. No
    /// window becomes key, so the app in front keeps the keyboard.
    func summon() {
        guard isCollapsed, !latestEntries.isEmpty else { return }
        isCollapsed = false
        foldGeneration += 1
        lastAttended = .now
        stopWatchingForShake()
        Log.app.notice("Dock unfolded")
        redock()
        updateIdleTimer()
    }

    /// Folds the dock to its handle. Not while a card is open.
    func collapse() {
        guard !isCollapsed, !latestEntries.isEmpty,
              !managed.values.contains(where: { $0.presentation.isExpanded }) else { return }
        isCollapsed = true
        foldGeneration += 1
        Log.app.notice("Dock folded")
        redock()
        updateIdleTimer()
        watchForShake()
    }

    func removeAll() {
        for item in managed.values {
            for panel in item.panels { panel.orderOut(nil); panel.close() }
        }
        managed.removeAll()
        latestEntries = []
        unfoldQuietly()
    }

    // AppKit orders the menu-bar display first; NSScreen.main can follow a key window
    // onto a secondary display, which would make the dock jump away from the menu bar.
    private var mainScreen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }

    private func makeManaged(_ entry: BackgroundJobs.Entry) -> Managed {
        let presentation = CapsulePresentation(entry: entry)
        let id = entry.id
        let tileHost = FirstClickHostingView(rootView: DockTileView(presentation: presentation,
                                                                    onToggle: { [weak self] in self?.toggle(id) }))
        let tileSide = AgentDock.tileSize + 2 * Self.tileMargin
        let tile = Self.makePanel(CGRect(x: 0, y: 0, width: tileSide, height: tileSide))
        tileHost.autoresizingMask = [.width, .height]
        tile.contentView = tileHost
        tile.ignoresMouseEvents = false
        return Managed(presentation: presentation, tile: tile)
    }

    private func makeCard(for item: Managed) -> (Panel, NSHostingView<CapsuleView>) {
        if let card = item.card, let host = item.cardHost { return (card, host) }
        let presentation = item.presentation
        let cardHost = FirstClickHostingView(rootView: CapsuleView(presentation: presentation,
                                                                   onStop: { [weak self] in self?.onStop?($0) },
                                                                   onGoThere: { [weak self] in self?.onGoThere?($0) },
                                                                   onLater: { [weak self] in self?.onLater?($0) },
                                                                   onDismiss: { [weak self] in self?.onDismiss?($0) },
                                                                   onSuggestion: { [weak self] in self?.onSuggestion?($0, $1) },
                                                                   onFollowUp: { [weak self] in self?.followUp($0, $1) },
                                                                   microphoneLevel: { [weak self] in self?.cardMicrophoneLevel?() ?? 0 },
                                                                   canGoThere: { [weak self] in self?.canGoThere?() ?? true }))
        let card = Self.makePanel(CGRect(x: 0, y: 0, width: AgentDock.cardWidth, height: 100))
        cardHost.autoresizingMask = [.width, .height]
        card.contentView = cardHost
        item.card = card
        item.cardHost = cardHost
        return (card, cardHost)
    }

    private static func makePanel(_ frame: CGRect) -> Panel {
        let panel = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = WindowLayers.dock  // above the notch panel (`WindowLayers`)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        return panel
    }

    private func toggle(_ id: UUID) {
        guard let item = managed[id] else { return }
        if item.presentation.isExpanded {
            item.presentation.isExpanded = false
            redock()
        } else {
            open(item)
        }
    }

    private func open(_ item: Managed) {
        item.presentation.isExpanded = true
        if !item.presentation.entry.job.isWorking { onSeen?(item.presentation.entry.id) }
        redock()
    }

    private func redock() {
        guard let screen = mainScreen else { return }
        let visible = Self.rect(screen.visibleFrame)
        for (index, entry) in latestEntries.enumerated() {
            guard let slot = AgentDock.tile(index, in: visible), let item = managed[entry.id] else { continue }
            let tileFrame = CGRect(x: slot.x, y: slot.y, width: slot.width, height: slot.height)
                .insetBy(dx: -Self.tileMargin, dy: -Self.tileMargin)
            if isCollapsed {
                fold(item.tile, at: tileFrame)
            } else {
                place(item.tile, at: tileFrame, appearing: AgentDock.growTime)
                placeCard(item, under: slot, in: visible)
            }
        }
        placeHandle(in: visible)
    }

    /// Reduce Motion: fades only, no slide.
    private var slide: CGFloat {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : DockCollapse.slide
    }

    /// A tile fades out toward the edge, lets clicks through at once, and leaves the screen
    /// when the fade ends (unless the dock came back meanwhile).
    private func fold(_ panel: Panel, at frame: CGRect) {
        panel.ignoresMouseEvents = true
        guard panel.isVisible, !panel.folding else {
            if !panel.isVisible { panel.setFrame(frame, display: false) }
            return
        }
        panel.folding = true
        let generation = foldGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DockCollapse.fadeOutTime
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frame.offsetBy(dx: slide, dy: 0), display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.foldGeneration == generation, panel.folding else { return }
                panel.orderOut(nil)
                panel.setFrame(frame, display: false)
            }
        }
    }

    /// The handle shows only while the dock is folded, in the colour of what's waiting.
    private func placeHandle(in visible: Rect) {
        handleModel.dot = DockCollapse.handleDot(latestEntries.map {
            (CapsulePresentation.status(of: $0.job), $0.seen)
        })
        handleModel.count = latestEntries.count
        let bar = DockCollapse.handle(in: visible)
        let margin = DockCollapse.handleHitMargin
        let frame = CGRect(x: bar.x - margin, y: bar.y - margin, width: bar.width + 2 * margin, height: bar.height + 2 * margin)
        if isCollapsed {
            let panel = handle ?? makeHandle(frame)
            handle = panel
            panel.ignoresMouseEvents = false
            panel.setFrame(frame, display: false)
            guard !panel.isVisible || panel.alphaValue < 1 else { return }
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DockCollapse.fadeInTime
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else if let panel = handle, panel.isVisible {
            panel.ignoresMouseEvents = true
            let generation = foldGeneration
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.foldGeneration == generation, !self.isCollapsed else { return }
                    panel.orderOut(nil)
                }
            }
        }
    }

    private func makeHandle(_ frame: CGRect) -> Panel {
        let panel = Self.makePanel(frame)
        let host = FirstClickHostingView(rootView: DockHandleView(model: handleModel, onSummon: { [weak self] in
            Log.app.notice("Dock handle clicked")
            self?.summon()
        }))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// No jobs left: nothing to fold, no handle, nothing watching.
    private func unfoldQuietly() {
        isCollapsed = false
        foldGeneration += 1
        stopWatchingForShake()
        idleTimer?.invalidate()
        idleTimer = nil
        handle?.orderOut(nil)
    }

    // MARK: Folding when left alone

    /// Checks twice a second while the dock is open, and only then.
    private func updateIdleTimer() {
        let needed = !isCollapsed && !latestEntries.isEmpty
        if !needed {
            idleTimer?.invalidate()
            idleTimer = nil
        } else if idleTimer == nil {
            idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkIdle() }
            }
        }
    }

    private func checkIdle() {
        let pointer = NSEvent.mouseLocation
        let cardOpen = managed.values.contains { $0.presentation.isExpanded }
        let over = managed.values.contains { item in
            item.panels.contains { $0.isVisible && $0.frame.insetBy(dx: -12, dy: -12).contains(pointer) }
        }
        // VoiceOver may be reading the tiles without the pointer near them: don't pull them away.
        if over || cardOpen || NSWorkspace.shared.isVoiceOverEnabled { lastAttended = .now }
        let idle = ContinuousClock.now - lastAttended
        let seconds = Double(idle.components.seconds) + Double(idle.components.attoseconds) / 1e18
        if DockCollapse.foldsWhenIdle(cardOpen: cardOpen, pointerOver: over, idleFor: seconds) { collapse() }
    }

    // MARK: Shaking it back

    /// Pointer moves are watched only while folded, and only near the handle count.
    private func watchForShake() {
        guard moveMonitors.isEmpty else { return }
        shake.reset()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved(NSEvent.mouseLocation) }
        }) {
            moveMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved(NSEvent.mouseLocation) }
            return event
        }) {
            moveMonitors.append(local)
        }
    }

    private func stopWatchingForShake() {
        moveMonitors.forEach(NSEvent.removeMonitor)
        moveMonitors.removeAll()
        shake.reset()
    }

    private func pointerMoved(_ point: CGPoint) {
        guard isCollapsed, let screen = mainScreen else { return }
        let zone = DockCollapse.shakeZone(in: Self.rect(screen.visibleFrame))
        guard point.x >= zone.minX, point.x <= zone.maxX, point.y >= zone.minY, point.y <= zone.maxY else {
            shake.reset()
            return
        }
        if shake.add(x: point.x, at: ProcessInfo.processInfo.systemUptime) {
            Log.app.notice("Dock shaken back")
            summon()
        }
    }

    /// New windows fade in (after `delay`); moved ones slide, as the tiles below make room
    /// while a peel flies (`AgentDock.slide`).
    private func place(_ panel: Panel, at frame: CGRect, appearing delay: Double) {
        panel.ignoresMouseEvents = false
        if panel.folding {
            // Coming back from a fold (or mid-fold): fade in from where it is, slide back.
            panel.folding = false
            if !panel.isVisible { panel.setFrame(frame.offsetBy(dx: slide, dy: 0), display: true) }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DockCollapse.fadeInTime
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
            return
        }
        if !panel.isVisible {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard !panel.folding else { return }  // folded before it finished appearing
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = AgentDock.flightTime * AgentDock.tileShare
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        panel.animator().alphaValue = 1
                    }
                }
            }
            return
        }
        panel.orderFrontRegardless()
        guard panel.frame != frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AgentDock.growTime + AgentDock.flightTime * AgentDock.tileShare
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: The done card's mini-chat

    func followUp(_ id: UUID, _ action: FollowUpAction) {
        guard let item = managed[id] else { return }
        var panel = item.presentation.followUp
        let effect: FollowUpPanel.Effect
        switch action {
        case .tap(let mode): effect = panel.tap(mode)
        case .collapse: effect = panel.collapse()
        case .draft(let text): panel.draft = text; effect = .none
        case .submit: effect = panel.submit(answering: item.presentation.status == .working)
        }
        if case .tap(let mode) = action {
            Log.app.notice("Card follow-up: \(String(describing: mode), privacy: .public) tapped → \(String(describing: effect), privacy: .public)")
        }
        item.presentation.followUp = panel
        perform(effect, for: item)
        if case .draft = action { return }  // typing changes no size or focus
        settleFollowUp(item)
    }

    #if DEBUG
    func followUpState(_ id: UUID) -> String { managed[id].map { "\($0.presentation.followUp.isOpen ? "open" : "closed") \($0.presentation.followUp.voice)" } ?? "gone" }
    #endif

    private func perform(_ effect: FollowUpPanel.Effect, for item: Managed) {
        let id = item.presentation.entry.id
        switch effect {
        case .none:
            break
        case .startRecording:
            if let reason = onCardVoiceStart?() {
                item.presentation.followUp.recordingFailed(reason)
            } else {
                item.presentation.followUp.recordingStarted()
            }
        case .cancelRecording:
            onCardVoiceCancel?()
        case .stopRecording:
            Task { @MainActor [weak self] in
                guard let self, let result = await onCardVoiceFinish?() else { return }
                var panel = item.presentation.followUp
                switch result {
                case .success(let words): panel.transcribed(words)  // to review, not sent
                case .failure(let error): panel.recordingFailed(error.message)
                }
                item.presentation.followUp = panel
                settleFollowUp(item)
            }
        case .send(let text):
            if let reason = onFollowUpSend?(id, text) {
                item.presentation.followUp.sendFailed(text, reason: reason)
            }
        }
    }

    /// The card's window takes the keyboard only while typing, and resizes to the panel.
    private func settleFollowUp(_ item: Managed) {
        let typing = item.presentation.followUp.isOpen
        if let card = item.card {
            card.takesKeyboard = typing
            if typing { card.makeKey() } else if card.isKeyWindow { card.resignKey() }
        }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.redock() } }
    }

    private func placeCard(_ item: Managed, under slot: Rect, in visible: Rect) {
        guard item.presentation.isExpanded else {
            // A folded card keeps its mini-chat for when it reopens; a recording is dropped.
            if item.presentation.followUp.voice.isBusy {
                perform(item.presentation.followUp.pause(), for: item)
            }
            item.card?.takesKeyboard = false
            if let card = item.card, card.isVisible {
                card.ignoresMouseEvents = true
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    card.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated { if card.alphaValue == 0 { card.orderOut(nil) } }
                }
            }
            return
        }
        let (panel, host) = makeCard(for: item)
        let margin = Self.cardMargin
        let fitting = host.fittingSize
        let card = AgentDock.card(under: slot, height: fitting.height - 2 * margin, in: visible)
        let frame = CGRect(x: card.x - margin, y: card.y - margin,
                           width: card.width + 2 * margin, height: card.height + 2 * margin)
        panel.ignoresMouseEvents = false
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.setFrame(frame.offsetBy(dx: 0, dy: 6), display: true)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        } else if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    private func collapseOutside(_ point: CGPoint) {
        let cardOpen = managed.values.contains { $0.presentation.isExpanded }
        let inside = managed.values.contains { $0.panels.contains { $0.isVisible && $0.frame.contains(point) } }
        if !isCollapsed, DockCollapse.foldsOnClick(cardOpen: cardOpen, insideDock: inside) {
            collapse()
            return
        }
        var changed = false
        for item in managed.values where item.presentation.isExpanded
            && !item.panels.contains(where: { $0.frame.contains(point) }) {
            item.presentation.isExpanded = false
            changed = true
        }
        if changed { redock() }
    }

    private static func rect(_ frame: CGRect) -> Rect {
        Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }
}
