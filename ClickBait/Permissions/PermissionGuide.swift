import AppKit
import QuartzCore
import SwiftUI

/// A small floating card beside System Settings for the grants macOS won't prompt for again
/// (Screen Recording, Accessibility): `guide(_:isGranted:)` opens the pane, and the card flies
/// from the button just pressed to under the Settings window and follows it
/// (`SettingsWindowTracker`). It says what to switch on and carries ClickBait's app card to
/// drag into the list when ClickBait isn't there. It closes itself once the permission is
/// granted, when Settings closes, or on ✕. One at a time.
///
/// Adapted from Sentient OS (AGPL-3.0), itself adapted from PermissionFlow by 小弟调调
/// (MIT); see THIRD_PARTY_NOTICES.md.
@MainActor
@Observable
final class PermissionGuide {
    static let shared = PermissionGuide()
    private init() {}

    private(set) var kind: PermissionKind?
    /// While ClickBait's card is being dragged.
    private(set) var isDraggingApp = false
    /// Settings slipped behind something: the card offers to bring it back.
    private(set) var isSettingsFrontmost = false

    @ObservationIgnored private let tracker = SettingsWindowTracker()
    @ObservationIgnored private var panel: PermissionGuidePanel?
    @ObservationIgnored private var launchFrame: CGRect?
    @ObservationIgnored private var frontmostObserver: NSObjectProtocol?
    @ObservationIgnored private var grantCheck: Timer?

    static let appURL = Bundle.main.bundleURL

    var instruction: AttributedString {
        let markdown = "Turn **ClickBait** on in the list. Not there? Drag it in."
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }

    func guide(_ kind: PermissionKind, isGranted: @escaping @MainActor () -> Bool) {
        close()
        self.kind = kind
        let mouse = NSEvent.mouseLocation
        launchFrame = CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32)
        openSettings()

        let panel = PermissionGuidePanel(guide: self)
        self.panel = panel
        if let launchFrame { panel.show(at: launchFrame) }

        updateFrontmostState()
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrontmostState() }
        }
        tracker.onFrameChange = { [weak self] frame in self?.settingsFrameChanged(frame) }
        tracker.onTrackingEnded = { [weak self] in self?.close() }
        tracker.startTracking()
        grantCheck = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if isGranted() { self?.close() }
            }
        }
        Log.app.notice("Permission guide: \(kind.title, privacy: .public)")
    }

    /// Safe to call with nothing showing.
    func close() {
        tracker.stopTracking()
        grantCheck?.invalidate()
        grantCheck = nil
        panel?.close()
        panel = nil
        kind = nil
        launchFrame = nil
        isDraggingApp = false
        if let frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver)
            self.frontmostObserver = nil
        }
    }

    /// Brings a buried Settings pane back to the front.
    func reopenSettings() {
        openSettings()
        panel?.orderFrontRegardless()
    }

    /// While dragging, the card lets the mouse through so Settings gets the drop.
    func setDragging(_ dragging: Bool) {
        isDraggingApp = dragging
        panel?.setDraggingPassthrough(dragging)
    }

    /// The card never takes focus; poking it keeps Settings in front.
    func keepSettingsVisible() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.activate()
        panel?.orderFrontRegardless()
    }

    private func openSettings() {
        if let url = kind?.settingsURL { NSWorkspace.shared.open(url) }
    }

    private func settingsFrameChanged(_ frame: CGRect) {
        guard let panel else { return }
        if let launchFrame {
            panel.present(from: launchFrame, to: frame)
            self.launchFrame = nil
        } else {
            panel.snap(to: frame)
        }
    }

    private func updateFrontmostState() {
        isSettingsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences"
    }
}

// MARK: - The panel

/// Borderless and non-activating, so System Settings keeps focus. `sizingOptions = []` matters:
/// by default the hosting view re-advertises its size each layout pass and undoes every
/// `setFrame`, stranding the panel off-screen.
@MainActor
final class PermissionGuidePanel: NSPanel {
    private weak var guide: PermissionGuide?
    private let hostingView: NSHostingView<PermissionGuideView>
    private let sizingView: NSHostingView<PermissionGuideView>
    private let initialWidth: CGFloat = 420
    /// System Settings' sidebar: the card lines up with the content beside it.
    private let sidebarWidth: CGFloat = 230
    private let screenInset: CGFloat = 12
    private let minimumHeight: CGFloat = 96

    // The launch: a critically damped spring along a soft arc, settling while Settings moves.
    private let animationDuration: TimeInterval = 0.72
    private let animationResponse: Double = 0.72
    private let initialAlpha: CGFloat = 0.9
    private let minimumLaunchScale: CGFloat = 0.58
    private var launchTimer: Timer?
    private var launchStart: CFTimeInterval = 0
    private var launchFrom = NSRect.zero
    private var launchTo = NSRect.zero
    private var isLaunching = false

    init(guide: PermissionGuide) {
        self.guide = guide
        hostingView = NSHostingView(rootView: PermissionGuideView(guide: guide))
        sizingView = NSHostingView(rootView: PermissionGuideView(guide: guide))
        super.init(contentRect: CGRect(x: 0, y: 0, width: initialWidth, height: minimumHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.sizingOptions = []
        contentView = hostingView
        setContentSize(CGSize(width: initialWidth, height: measuredHeight(for: initialWidth)))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { guide?.keepSettingsVisible() }
        super.sendEvent(event)
    }

    /// Shown at the button before Settings' frame is known.
    func show(at source: CGRect) {
        stopLaunch()
        isLaunching = false
        alphaValue = 1
        setContentSize(CGSize(width: frame.width, height: measuredHeight(for: frame.width)))
        setFrame(launchSourceFrame(for: source), display: false)
        orderFrontRegardless()
    }

    /// Flies from the button to the Settings window.
    func present(from source: CGRect, to settingsFrame: CGRect) {
        stopLaunch()
        let target = targetFrame(for: settingsFrame)
        guard !source.isEmpty else {
            isLaunching = false
            alphaValue = 1
            setFrame(target, display: false)
            orderFrontRegardless()
            return
        }
        isLaunching = true
        launchFrom = launchSourceFrame(for: source)
        launchTo = target
        launchStart = CACurrentMediaTime()
        alphaValue = initialAlpha
        setFrame(launchFrom, display: false)
        orderFrontRegardless()
        stepLaunch()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepLaunch() }
        }
        RunLoop.main.add(timer, forMode: .common)
        launchTimer = timer
    }

    func setDraggingPassthrough(_ dragging: Bool) {
        ignoresMouseEvents = dragging
        alphaValue = dragging ? 0.72 : 1
        if dragging { orderBack(nil) } else { orderFrontRegardless() }
    }

    /// Follows Settings; mid-launch only the destination moves, so the flight stays smooth.
    func snap(to settingsFrame: CGRect) {
        let target = targetFrame(for: settingsFrame)
        if isLaunching { launchTo = target; return }
        stopLaunch()
        setFrame(target, display: false)
        orderFrontRegardless()
    }

    /// Under the Settings window, lined up with its content past the sidebar, kept on screen.
    private func targetFrame(for settingsFrame: CGRect) -> CGRect {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(settingsFrame) })?.visibleFrame ?? settingsFrame
        let width = min(max(240, settingsFrame.width - sidebarWidth), screen.width - screenInset * 2)
        let height = measuredHeight(for: width)
        var origin = CGPoint(x: settingsFrame.minX + sidebarWidth, y: settingsFrame.minY - height)
        origin.x = max(screen.minX + screenInset, min(origin.x, screen.maxX - width - screenInset))
        origin.y = max(screen.minY + screenInset, min(origin.y, screen.maxY - height - screenInset))
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private func launchSourceFrame(for source: CGRect) -> CGRect {
        let size = CGSize(width: max(source.width, frame.width * minimumLaunchScale),
                          height: max(source.height, frame.height * minimumLaunchScale))
        return CGRect(x: source.midX - size.width / 2, y: source.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func measuredHeight(for width: CGFloat) -> CGFloat {
        sizingView.setFrameSize(NSSize(width: width, height: 4096))
        sizingView.layoutSubtreeIfNeeded()
        return max(minimumHeight, sizingView.fittingSize.height)
    }

    private func stepLaunch() {
        let elapsed = max(0, CACurrentMediaTime() - launchStart)
        guard elapsed < animationDuration else {
            isLaunching = false
            stopLaunch()
            alphaValue = 1
            setFrame(launchTo, display: true)
            return
        }
        let omega = 2 * Double.pi / animationResponse
        let progress = CGFloat(min(max(1 - exp(-omega * elapsed) * (1 + omega * elapsed), 0), 1))
        alphaValue = initialAlpha + (1 - initialAlpha) * progress
        setFrame(curvedFrame(from: launchFrom, to: launchTo, progress: progress), display: true)
    }

    private func stopLaunch() {
        launchTimer?.invalidate()
        launchTimer = nil
    }

    /// A quadratic Bézier between the centres, lifted in the middle: a soft arc.
    private func curvedFrame(from: CGRect, to: CGRect, progress t: CGFloat) -> CGRect {
        let size = CGSize(width: from.width + (to.width - from.width) * t, height: from.height + (to.height - from.height) * t)
        let start = CGPoint(x: from.midX, y: from.midY), end = CGPoint(x: to.midX, y: to.midY)
        let lift = min(140, max(44, hypot(end.x - start.x, end.y - start.y) * 0.18))
        let control = CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + lift)
        let u = 1 - t
        let centre = CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                             y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
        return CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
    }
}

// MARK: - The card

struct PermissionGuideView: View {
    let guide: PermissionGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: guide.isDraggingApp ? "arrowshape.up.fill" : "switch.2")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(CompanionTone.action.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(guide.kind?.title.uppercased() ?? "")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(.secondary)
                    Text(guide.instruction)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !guide.isSettingsFrontmost {
                    Button { guide.reopenSettings() } label: {
                        Image(systemName: "gear").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Show System Settings")
                }
                Button { guide.close() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
            }
            AppDragItem(url: PermissionGuide.appURL) { guide.setDragging($0) }
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: Look.Corner.card, style: .continuous)
            .fill(Color.black)
            .overlay(RoundedRectangle(cornerRadius: Look.Corner.card, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - The drag source

private struct AppDragItem: NSViewRepresentable {
    let url: URL
    let onDragStateChange: (Bool) -> Void

    func makeNSView(context: Context) -> AppDragSourceView {
        let view = AppDragSourceView(url: url)
        view.onDragStateChange = onDragStateChange
        return view
    }

    func updateNSView(_ view: AppDragSourceView, context: Context) {
        view.onDragStateChange = onDragStateChange
    }
}

/// Drags the app the way Finder does: the pasteboard mix System Settings' privacy lists accept
/// (file URL, `NSFilenamesPboardType`, promised file URL, string), with the app icon.
final class AppDragSourceView: NSView, NSDraggingSource {
    private let url: URL
    private let hostingView: NSHostingView<AnyView>
    private var mouseDownPoint: NSPoint?
    private var hasBegunDragging = false
    var onDragStateChange: ((Bool) -> Void)?

    init(url: URL) {
        self.url = url
        hostingView = NSHostingView(rootView: AnyView(AppDragCard(url: url).allowsHitTesting(false)))
        super.init(frame: .zero)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(52, hostingView.fittingSize.height))
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        hasBegunDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hasBegunDragging, let mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
        hasBegunDragging = true
        let item = NSDraggingItem(pasteboardWriter: AppBundlePasteboardWriter(url: url))
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 56, height: 56)
        item.setDraggingFrame(NSRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56), contents: icon)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        hasBegunDragging = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { onDragStateChange?(true) }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragStateChange?(false)
        mouseDownPoint = nil
        hasBegunDragging = false
    }
}

private final class AppBundlePasteboardWriter: NSObject, NSPasteboardWriting {
    private let url: URL
    private static let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let promised = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")

    init(url: URL) { self.url = url }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, Self.filenames, Self.promised, .string]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL, Self.promised: url.absoluteString
        case Self.filenames: [url.path]
        case .string: url.path
        default: nil
        }
    }
}

private struct AppDragCard: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            Text(FileManager.default.displayName(atPath: url.path))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            VStack(spacing: 1) {
                Image(systemName: "hand.draw").font(.system(size: 13))
                Text("DRAG").font(.system(size: 7, weight: .semibold, design: .monospaced)).tracking(1.4)
            }
            .foregroundStyle(Color.white.opacity(0.6))
            .padding(.trailing, 4)
        }
        .padding(8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Look.Corner.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Look.Corner.tile, style: .continuous)
            .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
