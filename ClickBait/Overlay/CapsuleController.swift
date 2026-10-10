import AppKit
import ClickBaitCore
import SwiftUI

@MainActor
final class CapsuleController {
    var onGoThere: ((UUID) -> Void)?
    var onStop: ((UUID) -> Void)?
    var onLater: ((UUID) -> Void)?
    var onDismiss: ((UUID) -> Void)?
    var canGoThere: (() -> Bool)?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private struct Managed {
        let panel: Panel
        let presentation: CapsulePresentation
        let host: NSHostingView<CapsuleView>
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
            let exitFrame = item.panel.frame.offsetBy(dx: CapsuleLayout.capsuleWidth / 2, dy: 0)
            item.panel.ignoresMouseEvents = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                item.panel.animator().setFrame(exitFrame, display: true)
                item.panel.animator().alphaValue = 0
            } completionHandler: {
                // AppKit runs this on the main thread, but doesn't say so to Swift.
                MainActor.assumeIsolated {
                    item.panel.orderOut(nil)
                    item.panel.close()
                }
            }
        }
        for entry in entries {
            if let item = managed[entry.id] {
                item.presentation.entry = entry
            } else {
                managed[entry.id] = makeManaged(entry)
            }
        }
        redock()
    }

    func slotCenter(forIndex index: Int) -> CGPoint? {
        guard let screen = mainScreen, let slot = CapsuleLayout.slot(index, in: Self.rect(screen.visibleFrame)) else { return nil }
        return CGPoint(x: slot.x + slot.width / 2, y: slot.y + slot.height / 2)
    }

    func fold(_ id: UUID) {
        guard let item = managed[id] else { return }
        item.presentation.isExpanded = false
        item.presentation.isMinimized = true
        redock()
    }

    func expand(_ id: UUID) {
        guard let item = managed[id] else {
            Log.app.error("Background capsule recall target was missing")
            return
        }
        Log.app.notice("Background capsule expanded from menu")
        item.presentation.isMinimized = false
        item.presentation.isExpanded = true
        redock()
    }

    func removeAll() {
        for item in managed.values { item.panel.orderOut(nil); item.panel.close() }
        managed.removeAll()
        latestEntries = []
    }

    // AppKit orders the menu-bar display first; NSScreen.main can follow a key window
    // onto a secondary display, which would make the dock jump away from the menu bar.
    private var mainScreen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }

    private func makeManaged(_ entry: BackgroundJobs.Entry) -> Managed {
        let presentation = CapsulePresentation(entry: entry)
        let host = NSHostingView(rootView: CapsuleView(presentation: presentation,
                                                       onStop: { [weak self] in self?.onStop?($0) },
                                                       onGoThere: { [weak self] in self?.onGoThere?($0) },
                                                       onLater: { [weak self] in self?.onLater?($0) },
                                                       onDismiss: { [weak self] in self?.onDismiss?($0) },
                                                       canGoThere: { [weak self] in self?.canGoThere?() ?? true },
                                                       onLayoutChange: { [weak self] in self?.redock() }))
        let panel = Panel(contentRect: CGRect(x: 0, y: 0, width: CapsuleLayout.capsuleWidth, height: CapsuleLayout.capsuleHeight),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return Managed(panel: panel, presentation: presentation, host: host)
    }

    private func redock() {
        guard let screen = mainScreen else { return }
        let visible = Self.rect(screen.visibleFrame)
        for (index, entry) in latestEntries.enumerated() {
            guard let slot = CapsuleLayout.slot(index, in: visible), let item = managed[entry.id] else { continue }
            item.presentation.entry = entry
            let frame: CGRect
            if item.presentation.isExpanded {
                let card = CapsuleLayout.card(under: slot, height: 136, in: visible)
                frame = CGRect(x: min(slot.minX, card.minX), y: card.minY,
                               width: max(slot.maxX, card.maxX) - min(slot.minX, card.minX), height: slot.maxY - card.minY)
            } else {
                frame = CGRect(x: slot.x, y: slot.y, width: slot.width, height: slot.height)
            }

            // Keep the collapsed chip click-through; an expanded card accepts its
            // controls. Window geometry animates with the SwiftUI card transition.
            item.panel.ignoresMouseEvents = !item.presentation.isExpanded
            if item.panel.alphaValue == 0 {
                item.panel.setFrame(frame, display: true)
                item.panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    item.panel.animator().alphaValue = 1
                }
            } else {
                item.panel.orderFrontRegardless()
                guard item.panel.frame != frame else { continue }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.24
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    item.panel.animator().setFrame(frame, display: true)
                }
            }
        }
    }

    private func collapseOutside(_ point: CGPoint) {
        var changed = false
        for item in managed.values where item.presentation.isExpanded && !item.panel.frame.contains(point) {
            item.presentation.isExpanded = false
            changed = true
        }
        if changed { redock() }
    }

    private static func rect(_ frame: CGRect) -> Rect {
        Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }
}
