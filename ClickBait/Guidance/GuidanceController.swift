import AppKit
import ClickBaitCore
import SwiftUI

/// What a guide is about. AppKit screen coordinates (y up) for explicit bounds and points.
enum GuideTarget {
    /// An element of the app in front, by its `AXIdentifier` (or else its name).
    case element(id: String, pid: pid_t)
    /// An accessibility node: tracked as it moves.
    case node(AXUIElement)
    case bounds(CGRect)
    case point(CGPoint)
}

/// One guide to show (`GuidanceController.show`).
struct GuideRequest {
    var kind: GuideKind
    var target: GuideTarget
    var label: String?
    /// Higher wins: the primary guide stays on top at full strength.
    var priority = 0
    /// Catches the next click on the target, then calls `onArmedClick` and goes away.
    var armed = false
    var pulse = false
    var onArmedClick: (() -> Void)?
}

/// Lets the caller change or remove its guide.
@MainActor
final class GuideHandle {
    let id = UUID()
    fileprivate weak var controller: GuidanceController?

    /// Changes what's shown (nil leaves a field as it is).
    func update(label: String? = nil, target: GuideTarget? = nil, priority: Int? = nil, armed: Bool? = nil) {
        controller?.update(id, label: label, target: target, priority: priority, armed: armed)
    }

    func dismiss() { controller?.dismiss(id) }
}

/// Visual guidance on screen: blue highlights (mode A) and arrows (mode B) from one API
/// (`Guidance` in Core holds the geometry: padding, label placement, arrow direction, stacking,
/// armed hits). Click-through always: the overlay never takes a click. An armed guide watches
/// for the next click on its target (the click still reaches the app — that's the step being
/// done) and then advances. Targets given as elements or accessibility nodes are re-read twice a
/// second while any such guide shows (layout moves, windows resize, scrolling); nothing runs
/// while there are no guides.
///
///     // Mode A: highlight a region, informational, label placed clear of the box.
///     let recent = guidance.show(GuideRequest(kind: .highlight,
///                                             target: .bounds(CGRect(x: 120, y: 520, width: 300, height: 140)),
///                                             label: "Your recent files"))
///
///     // Mode B: point at the Share button, pulsing, armed: its click moves the walkthrough on.
///     let share = guidance.show(GuideRequest(kind: .arrow, target: .element(id: "Share", pid: safariPID),
///                                            label: "Click Share", priority: 2, armed: true, pulse: true,
///                                            onArmedClick: { tutorial.next() }))
///
///     share.update(label: "Now choose Copy Link")   // change it
///     recent.dismiss()                               // or remove it
@MainActor
final class GuidanceController {
    fileprivate struct Guide {
        var request: GuideRequest
        var resolved: (bounds: Rect?, point: Point?)
    }

    @MainActor @Observable
    final class Model {
        /// Laid out, in the overlay's own coordinates (y down), bottom to top.
        var items: [Item] = []
        struct Item: Identifiable {
            let id: UUID
            let kind: GuideKind
            let box: CGRect?
            let tip: CGPoint?
            let tail: CGPoint?
            let label: String?
            let labelFrame: CGRect?
            let opacity: Double
            let isPrimary: Bool
            let pulse: Bool
        }
    }

    private var guides: [UUID: Guide] = [:]
    private var order: [UUID] = []
    private var panel: NSPanel?
    private let model = Model()
    private var trackTimer: Timer?
    private var clickMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var layouts: [UUID: GuideLayout] = [:]

    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    // MARK: API

    @discardableResult
    func show(_ request: GuideRequest) -> GuideHandle {
        let handle = GuideHandle()
        handle.controller = self
        guides[handle.id] = Guide(request: request, resolved: resolve(request.target))
        order.append(handle.id)
        if let label = request.label {
            // VoiceOver hears each guide as it appears.
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "Guide: \(label)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        relayout()
        return handle
    }

    fileprivate func update(_ id: UUID, label: String?, target: GuideTarget?, priority: Int?, armed: Bool?) {
        guard var guide = guides[id] else { return }
        if let label { guide.request.label = label }
        if let target { guide.request.target = target; guide.resolved = resolve(target) }
        if let priority { guide.request.priority = priority }
        if let armed { guide.request.armed = armed }
        guides[id] = guide
        relayout()
    }

    func dismiss(_ id: UUID) {
        guides[id] = nil
        order.removeAll { $0 == id }
        relayout()
    }

    func dismissAll() {
        guides.removeAll()
        order.removeAll()
        relayout()
    }

    // MARK: Targets

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// AppKit geometry for a target; accessibility frames are Quartz (y down) and are flipped.
    private func resolve(_ target: GuideTarget) -> (bounds: Rect?, point: Point?) {
        let height = Double(Self.primaryHeight)
        let flip = { (quartz: Rect) in Rect(x: quartz.x, y: height - quartz.y - quartz.height, width: quartz.width, height: quartz.height) }
        switch target {
        case .element(let id, let pid): return (AXInspector.frame(ofElement: id, pid: pid).map(flip), nil)
        case .node(let node): return (AXInspector.frame(of: node).map(flip), nil)
        case .bounds(let rect): return (Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height), nil)
        case .point(let point): return (nil, Point(x: point.x, y: point.y))
        }
    }

    private var tracksLayout: Bool {
        guides.values.contains {
            switch $0.request.target {
            case .element, .node: true
            case .bounds, .point: false
            }
        }
    }

    // MARK: Layout

    private func relayout() {
        guard !order.isEmpty, let screen = targetScreen() else {
            panel?.orderOut(nil)
            model.items = []
            stopWatching()
            return
        }
        let frame = screen.frame
        let screenRect = Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        let ids = order.filter { guides[$0]?.resolved.bounds != nil || guides[$0]?.resolved.point != nil }
        let specs = ids.compactMap { id -> GuideSpec? in
            guard let guide = guides[id] else { return nil }
            let r = guide.request
            return GuideSpec(kind: r.kind, bounds: guide.resolved.bounds, point: guide.resolved.point, label: r.label,
                             priority: r.priority, armed: r.armed, pulse: r.pulse)
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let placed = Guidance.layout(specs, screen: screenRect) { text in
            let size = (text as NSString).size(withAttributes: [.font: font])
            return (Double(size.width) + 20, 24)
        }
        layouts = Dictionary(uniqueKeysWithValues: zip(ids, placed))
        // AppKit (y up, global) → the overlay's own coordinates (y down).
        let local = { (p: Point) in CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y) }
        let localRect = { (r: Rect) in CGRect(x: r.x - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height) }
        model.items = zip(ids, zip(specs, placed))
            .sorted { $0.1.1.order < $1.1.1.order }
            .map { id, pair in
                let (spec, layout) = pair
                return Model.Item(id: id, kind: spec.kind, box: layout.box.map(localRect), tip: layout.tip.map(local),
                                  tail: layout.tail.map(local), label: spec.label, labelFrame: layout.label.map(localRect),
                                  opacity: layout.opacity, isPrimary: layout.isPrimary, pulse: spec.pulse)
            }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
        watch()
    }

    /// The screen under the first guide's target (else the main one).
    private func targetScreen() -> NSScreen? {
        let first = order.compactMap { guides[$0]?.resolved }.first
        let point = first?.point.map { CGPoint(x: $0.x, y: $0.y) } ?? first?.bounds.map { CGPoint(x: $0.midX, y: $0.midY) }
        return point.flatMap { p in NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } } ?? NSScreen.screens.first
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true  // never blocks: armed clicks are watched, not taken
        panel.level = WindowLayers.guidance
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: GuidanceOverlay(model: model))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    // MARK: Tracking and armed clicks

    private func watch() {
        if tracksLayout, trackTimer == nil {
            trackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.retrack() }
            }
        } else if !tracksLayout {
            trackTimer?.invalidate()
            trackTimer = nil
        }
        let armed = guides.values.contains { $0.request.armed }
        if armed, clickMonitors.isEmpty {
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.clicked(at: NSEvent.mouseLocation) }
            }) { clickMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.clicked(at: NSEvent.mouseLocation) }
                return event
            }) { clickMonitors.append(local) }
        } else if !armed {
            clickMonitors.forEach(NSEvent.removeMonitor)
            clickMonitors.removeAll()
        }
    }

    private func stopWatching() {
        trackTimer?.invalidate()
        trackTimer = nil
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
    }

    /// Elements and nodes re-read: a guide follows its target when the layout moves.
    private func retrack() {
        var moved = false
        for id in order {
            guard var guide = guides[id] else { continue }
            switch guide.request.target {
            case .element, .node:
                let now = resolve(guide.request.target)
                if now.bounds != guide.resolved.bounds { guide.resolved = now; guides[id] = guide; moved = true }
            case .bounds, .point:
                break
            }
        }
        if moved { relayout() }
    }

    /// The highest-priority armed guide the click lands on advances (only one per click). The
    /// click itself still reaches the app.
    func clicked(at location: CGPoint) {
        let point = Point(x: location.x, y: location.y)
        let hit = order.reversed()
            .compactMap { id -> (id: UUID, spec: GuideSpec, layout: GuideLayout)? in
                guard let guide = guides[id], guide.request.armed, let layout = layouts[id] else { return nil }
                let r = guide.request
                return (id, GuideSpec(kind: r.kind, bounds: guide.resolved.bounds, point: guide.resolved.point,
                                      priority: r.priority, armed: true), layout)
            }
            .sorted { $0.spec.priority > $1.spec.priority }
            .first { Guidance.catches(point, guide: $0.spec, layout: $0.layout) }
        guard let hit else { return }
        let next = guides[hit.id]?.request.onArmedClick
        dismiss(hit.id)
        next?()
    }

    #if DEBUG
    /// `CLICKBAIT_TEST_GUIDANCE`: what's drawn, for the check.
    var debugItems: [Model.Item] { model.items }
    var debugOverlay: some View { GuidanceOverlay(model: model) }
    #endif
}

// MARK: - Drawing

/// The guides, bottom to top: highlights as a translucent system-blue rounded box with a subtle
/// border; arrows as a system-blue shaft and head whose point is the tip, with a pulse ring
/// (still with Reduce Motion); labels white on blue, VoiceOver-readable.
private struct GuidanceOverlay: View {
    let model: GuidanceController.Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let blue = Color(nsColor: .systemBlue)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.items) { item in
                Group {
                    if let box = item.box {
                        RoundedRectangle(cornerRadius: Guidance.cornerRadius, style: .continuous)
                            .fill(Self.blue.opacity(0.16))
                            .overlay(RoundedRectangle(cornerRadius: Guidance.cornerRadius, style: .continuous)
                                .strokeBorder(Self.blue.opacity(0.8), lineWidth: item.isPrimary ? 2 : 1.5))
                            .frame(width: box.width, height: box.height)
                            .position(x: box.midX, y: box.midY)
                            .accessibilityElement()
                            .accessibilityLabel(item.label.map { "Highlighted: \($0)" } ?? "Highlighted area")
                    }
                    if let tip = item.tip, let tail = item.tail {
                        if item.pulse, !reduceMotion { PulseRing(at: tip) }
                        ArrowShape(tip: tip, tail: tail)
                            .stroke(Self.blue, style: StrokeStyle(lineWidth: item.isPrimary ? 4 : 3, lineCap: .round, lineJoin: .round))
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .accessibilityElement()
                            .accessibilityLabel(item.label.map { "Arrow pointing to \($0)" } ?? "Arrow")
                    }
                    if let label = item.label, let frame = item.labelFrame {
                        Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(width: frame.width, height: frame.height)
                            .background(Self.blue, in: Capsule())
                            .position(x: frame.midX, y: frame.midY)
                            .accessibilityHidden(true)  // read with its guide
                    }
                }
                .opacity(item.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// The shaft from the tail to the tip, and the head's two strokes meeting exactly at the tip.
private struct ArrowShape: Shape {
    let tip: CGPoint
    let tail: CGPoint

    func path(in rect: CGRect) -> Path {
        let angle = atan2(tail.y - tip.y, tail.x - tip.x)
        let head: CGFloat = 13, spread: CGFloat = .pi / 7
        var path = Path()
        path.move(to: tail)
        path.addLine(to: tip)
        path.move(to: CGPoint(x: tip.x + cos(angle + spread) * head, y: tip.y + sin(angle + spread) * head))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x + cos(angle - spread) * head, y: tip.y + sin(angle - spread) * head))
        return path
    }
}

/// A ring growing and fading from the tip, once a second (drawn only while it shows).
private struct PulseRing: View {
    let at: CGPoint

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            Circle()
                .stroke(Color(nsColor: .systemBlue).opacity(0.6 * (1 - phase)), lineWidth: 2)
                .frame(width: 10 + 30 * phase, height: 10 + 30 * phase)
                .position(at)
        }
        .accessibilityHidden(true)
    }
}
