import AppKit
import ApplicationServices
import ClickBaitCore
import OSLog
import ScreenCaptureKit
import SwiftUI

/// ⌥⇥ window switching (user's asks, 2026-11-02, after AltTab, no AltTab code): hold ⌥, press ⇥ —
/// on the screen the pointer is on (laptop or monitor), every app's windows on that screen, on
/// any of its Spaces, minimised too, as thumbnails, most recent first, the one behind the front
/// selected; ⇥ / ⇧⇥ / ← → move; ⌥ let go (or ↩, or a click) brings it forward; Esc cancels.
/// Thumbnails come from ScreenCaptureKit (Screen Recording, which ClickBait has); bringing a
/// window forward uses Accessibility.
@MainActor
final class WindowSwitcher {
    static let shared = WindowSwitcher()
    var enabled: () -> Bool = { true }
    private var panel: NSPanel?
    private let model = SwitcherModel()
    /// Up, or its windows being listed (keys then already belong to it).
    private var opening = false
    var showing: Bool { panel != nil || opening }

    /// A key from the tap: true when taken.
    func handle(_ key: InputInterceptor.SwitcherKey) -> Bool {
        switch key {
        case .tab(let backwards):
            guard enabled() else { return false }
            if showing { model.move(backwards: backwards) } else { open(backwards: backwards) }
            return true
        case .left: guard showing else { return false }; model.move(backwards: true); return true
        case .right: guard showing else { return false }; model.move(backwards: false); return true
        case .escape: guard showing else { return false }; close(); return true
        case .choose: guard showing else { return false }; choose(); return true
        case .released:
            if opening { pendingChoose = true } else if showing { choose() }
            return false
        }
    }

    private var pendingChoose = false

    private func open(backwards: Bool) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        opening = true
        pendingChoose = false
        Task { @MainActor in
            await model.load(on: screen, backwards: backwards)
            opening = false
            guard !model.windows.isEmpty else { return }
            present(on: screen)
            if pendingChoose { choose() }  // ⌥ already let go: a quick flick switches straight away
        }
    }

    private func present(on screen: NSScreen) {
        let host = NSHostingView(rootView: SwitcherView(model: model, maxWidth: screen.visibleFrame.width - 80) { [weak self] index in
            self?.model.selected = index
            self?.choose()
        })
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2))
        panel.orderFrontRegardless()
        self.panel = panel
        Task { await model.loadThumbnails() }
    }

    #if DEBUG
    func logState() {
        Log.app.notice("Switcher up: \(self.model.windows.count, privacy: .public) windows from \(Set(self.model.windows.map(\.appName)).sorted().joined(separator: ", "), privacy: .public); \(self.model.windows.filter { $0.thumbnail != nil }.count, privacy: .public) pictured")
    }
    #endif

    private func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func choose() {
        let window = model.windows.indices.contains(model.selected) ? model.windows[model.selected] : nil
        close()
        guard let window else { return }
        Log.app.notice("Switcher: \(self.model.windows.count, privacy: .public) windows, \(self.model.windows.filter { $0.thumbnail != nil }.count, privacy: .public) pictured; to \(window.appName, privacy: .public)")
        Self.bringForward(window)
    }

    /// Its app brought forward the way the Dock does it (Launch Services: allowed from the
    /// background, and macOS goes to that app's Space — a plain `activate()` or Accessibility's
    /// "frontmost" was quietly refused: "doesn't take me anywhere", user's report, 2026-11-02),
    /// then the window itself raised as main, unminimised.
    static func bringForward(_ window: SwitcherModel.Item) {
        if window.id == 0 {
            // The desktop: Mission Control's own show desktop.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
            process.arguments = ["1"]
            try? process.run()
            return
        }
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        if app.isHidden { app.unhide() }
        raise(window)  // first, so the app comes forward on this window's Space
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                Task { @MainActor in
                    raise(window)  // again once in front: the right one of its windows on top
                    Log.app.notice("Switcher: to \(app.localizedName ?? "?", privacy: .public), front \(NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid, privacy: .public)")
                }
            }
        } else {
            app.activate()
        }
    }

    /// The window, matched by title and position through Accessibility: unminimised, main, raised.
    private static func raise(_ window: SwitcherModel.Item) {
        let element = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        func title(_ ax: AXUIElement) -> String {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(ax, kAXTitleAttribute as CFString, &title)
            return title as? String ?? ""
        }
        func origin(_ ax: AXUIElement) -> CGPoint? {
            var position: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &position) == .success, let position else { return nil }
            var point = CGPoint.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &point)  // an AXValue of cgPoint, as asked
            return point
        }
        // A window on another Space may not be in the app's list: coming forward goes there anyway.
        guard let match = windows.first(where: { title($0) == window.title && origin($0).map { abs($0.x - window.frame.minX) < 2 && abs($0.y - window.frame.minY) < 2 } ?? false })
            ?? windows.first(where: { title($0) == window.title }) else { return }
        AXUIElementSetAttributeValue(match, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(match, kAXRaiseAction as CFString)
    }
}

@MainActor @Observable
final class SwitcherModel {
    struct Item: Identifiable {
        let id: UInt32
        let pid: Int32
        let title: String
        let appName: String
        let icon: NSImage?
        /// In global top-left coordinates, as Core Graphics and Accessibility give them.
        let frame: CGRect
        var thumbnail: NSImage?
    }

    private(set) var windows: [Item] = []
    var selected = 0

    /// Every app's windows on `screen`, any Space, minimised too (ScreenCaptureKit lists them all;
    /// the titled ones are real windows, the untitled ones helpers), in macOS's front-to-back order.
    func load(on screen: NSScreen, backwards: Bool) async {
        let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        content.map { self.content = $0 }
        let order = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // The screen in Core Graphics' top-left coordinates, as window frames come.
        let primary = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let area = CGRect(x: screen.frame.minX, y: primary - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        let own = ProcessInfo.processInfo.processIdentifier
        let candidates = (content?.windows ?? []).compactMap { window -> (WindowSwitch.Window, SCWindow)? in
            guard let app = window.owningApplication, let title = window.title, !title.isEmpty,
                  area.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) else { return nil }
            return (WindowSwitch.Window(id: window.windowID, pid: app.processID, layer: window.windowLayer,
                                        width: window.frame.width, height: window.frame.height, title: title), window)
        }
        let kept = Set(WindowSwitch.eligible(candidates.map(\.0), own: own).map(\.id))
        windows = candidates.filter { kept.contains($0.0.id) }
            .sorted { (rank[$0.0.id] ?? .max) < (rank[$1.0.id] ?? .max) }
            .compactMap { window, scWindow in
                guard let app = NSRunningApplication(processIdentifier: window.pid), app.activationPolicy == .regular else { return nil }
                return Item(id: window.id, pid: window.pid, title: window.title, appName: app.localizedName ?? "", icon: app.icon, frame: scWindow.frame)
            }
        // The desktop, last (user's ask, 2026-11-02: "why is desktop not shown"): its wallpaper as
        // its picture; choosing it clears the windows away, as Mission Control's show desktop does.
        let wallpaper = NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
        windows.append(Item(id: 0, pid: 0, title: "Desktop", appName: "Desktop",
                            icon: NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app"), frame: screen.frame, thumbnail: wallpaper))
        selected = WindowSwitch.first(count: windows.count, backwards: backwards)
    }

    @ObservationIgnored private var content: SCShareableContent?

    func move(backwards: Bool) { selected = WindowSwitch.step(selected, count: windows.count, backwards: backwards) }

    /// Each window's picture, small, as they come.
    /// Each window's picture: the last one taken (`WindowPictures`) at once, then a fresh one
    /// wherever macOS allows it (ScreenCaptureKit's on-screen flag isn't reliable, so each is tried).
    func loadThumbnails() async {
        for index in windows.indices where windows[index].id != 0 { windows[index].thumbnail = WindowPictures.shared.picture(of: windows[index].id) }
        guard let content else { return }
        for index in windows.indices {
            guard let window = content.windows.first(where: { $0.windowID == windows[index].id }),
                  let picture = await WindowPictures.capture(window) else { continue }
            WindowPictures.shared.keep(picture, for: window.windowID)
            if windows.indices.contains(index), windows[index].id == window.windowID { windows[index].thumbnail = picture }
        }
    }
}

/// The windows' last pictures (user's report, 2026-11-02: "some only show app logos"): macOS
/// lets a window be captured only while it's on screen, so each is taken whenever it is — on
/// switching Space or app (`watch()`) and when the switcher opens — and shown from here when its
/// window is on another Space or minimised. Memory only, the newest 80; blocked apps never.
@MainActor
final class WindowPictures {
    static let shared = WindowPictures()
    var blocked: (String) -> Bool = { _ in false }
    private var pictures: [UInt32: NSImage] = [:]
    private var order: [UInt32] = []
    private var pending: Task<Void, Never>?

    func picture(of window: UInt32) -> NSImage? { pictures[window] }

    func keep(_ picture: NSImage, for window: UInt32) {
        pictures[window] = picture
        order.removeAll { $0 == window }
        order.append(window)
        while order.count > 80 { pictures[order.removeFirst()] = nil }
    }

    /// Takes the on-screen windows' pictures a moment after each Space or app switch.
    func watch() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.soon() }
            }
        }
        soon()
    }

    private func soon() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.takeOnScreen()
        }
    }

    private func takeOnScreen() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        for window in content.windows where window.windowLayer == 0 && !(window.title ?? "").isEmpty
            && window.frame.width >= 80 && window.frame.height >= 60 {
            guard let app = window.owningApplication, app.processID != own, !blocked(app.bundleIdentifier) else { continue }
            if let picture = await Self.capture(window) { keep(picture, for: window.windowID) }
        }
    }

    /// A window's picture, 360 pt wide (at 2×).
    static func capture(_ window: SCWindow) async -> NSImage? {
        let configuration = SCStreamConfiguration()
        let scale = 360 / max(window.frame.width, 1)
        configuration.width = Int(window.frame.width * scale * 2)
        configuration.height = Int(window.frame.height * scale * 2)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}

/// The switcher: a dark card of window thumbnails, the selected one outlined, its title below.
struct SwitcherView: View {
    @Bindable var model: SwitcherModel
    let maxWidth: CGFloat
    let pick: (Int) -> Void
    private let cardWidth: CGFloat = 200

    var body: some View {
        let columns = max(1, min(model.windows.count, Int((maxWidth - 32) / (cardWidth + 12))))
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: 12), count: columns), spacing: 12) {
            ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                VStack(spacing: 8) {
                    ZStack(alignment: .bottomLeading) {
                        Group {
                            if let thumbnail = window.thumbnail {
                                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                            } else {
                                // On another Space, or minimised: no picture to take, so its app, large.
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06))
                                    if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: 64, height: 64) }
                                }
                            }
                        }
                        .frame(width: cardWidth - 16, height: 120)
                        if let icon = window.icon, window.thumbnail != nil {
                            Image(nsImage: icon).resizable().frame(width: 32, height: 32).offset(x: -4, y: 8)
                        }
                    }
                    Text(window.title.isEmpty ? window.appName : window.title)
                        .font(.system(size: 12, weight: index == model.selected ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(index == model.selected ? 1 : 0.7))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: cardWidth - 16)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(index == model.selected ? 0.14 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(index == model.selected ? 0.5 : 0), lineWidth: 1.5))
                .contentShape(Rectangle())
                .onTapGesture { pick(index) }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .fixedSize()
    }
}
