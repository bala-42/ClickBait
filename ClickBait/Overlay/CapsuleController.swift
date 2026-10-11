import AppKit
import ClickBaitCore
import SwiftUI

/// The background dock (`AgentDock`): one small window per tile, top-right of the menu-bar
/// display, newest on top, and a second small window for a tile's card while it's open.
/// Small windows only: screen-sized ones on every desktop blacken Mission Control.
@MainActor
final class CapsuleController {
    var onGoThere: ((UUID) -> Void)?
    var onStop: ((UUID) -> Void)?
    var onLater: ((UUID) -> Void)?
    var onDismiss: ((UUID) -> Void)?
    var onSeen: ((UUID) -> Void)?
    var onSuggestion: ((UUID, String) -> Void)?
    var onFollowUp: ((UUID, Bool) -> Void)?
    var canGoThere: (() -> Bool)?

    /// Room around a tile and a card for their glows inside their windows.
    static let tileMargin: CGFloat = 12
    static let cardMargin: CGFloat = 22

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
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
        redock()
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
        open(item)
    }

    func removeAll() {
        for item in managed.values {
            for panel in item.panels { panel.orderOut(nil); panel.close() }
        }
        managed.removeAll()
        latestEntries = []
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
                                                                   onFollowUp: { [weak self] in self?.onFollowUp?($0, $1) },
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
        panel.level = .statusBar
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
            place(item.tile, at: tileFrame, appearing: AgentDock.growTime)
            placeCard(item, under: slot, in: visible)
        }
    }

    /// New windows fade in (after `delay`); moved ones slide, as the tiles below make room
    /// while a peel flies (`AgentDock.slide`).
    private func place(_ panel: Panel, at frame: CGRect, appearing delay: Double) {
        if !panel.isVisible {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
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

    private func placeCard(_ item: Managed, under slot: Rect, in visible: Rect) {
        guard item.presentation.isExpanded else {
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
