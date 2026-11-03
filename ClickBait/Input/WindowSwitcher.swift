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
            let began = ContinuousClock.now
            await model.load(on: screen, backwards: backwards)
            Log.app.notice("Switcher listed \(self.model.windows.count, privacy: .public) windows in \(String(describing: ContinuousClock.now - began), privacy: .public)")
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
        Log.app.notice("Switcher order: \(self.model.windows.prefix(4).map { "\($0.id) \($0.appName)" }.joined(separator: ", "), privacy: .public); selected \(self.model.selected, privacy: .public)")
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
        Log.app.notice("Switcher: \(self.model.windows.count, privacy: .public) windows, \(self.model.windows.filter { $0.thumbnail != nil }.count, privacy: .public) pictured; to \(window.appName, privacy: .public) window \(window.id, privacy: .public)")
        Self.bringForward(window)
    }

    /// Its app brought forward the way the Dock does it (Launch Services: allowed from the
    /// background, and macOS goes to that app's Space — a plain `activate()` or Accessibility's
    /// "frontmost" was quietly refused: "doesn't take me anywhere", user's report, 2026-11-02),
    /// then the window itself raised as main, unminimised.
    static func bringForward(_ window: SwitcherModel.Item) {
        WindowRecency.shared.used(window.id)
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
        // First, so the app comes forward on this window's Space. A window on another Space:
        // raising it there doesn't switch Space (Chrome came forward with its window here,
        // user's report, 2026-11-03), so a browser is asked for it by title — the app then comes
        // forward with it, and macOS goes to its Space.
        // A browser decides itself which of its windows comes forward with it (Chrome put its
        // last one back on top of the one raised): it's asked, by title, every time.
        raise(window)
        if let bundleID = app.bundleIdentifier, scriptable[bundleID] != nil { raiseInBrowser(window, bundleID: bundleID) }
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

    /// Accessibility's window → its window number (`_AXUIElementGetWindow`, private, what AltTab
    /// uses; looked up at run time like the brightness calls): an exact match, not by title.
    private typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    nonisolated(unsafe) private static let windowNumber: WindowNumber? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowNumber.self)
    }()

    /// Browsers that say which window to bring forward when asked by title (their own scripting):
    /// for a window Accessibility can't see — on another Space ("doesn't recognise the different
    /// Chrome windows", user's report, 2026-11-03). The window's title property, by browser.
    private static let scriptable: [String: String] = [
        "com.google.Chrome": "title", "com.brave.Browser": "title", "com.microsoft.edgemac": "title",
        "com.vivaldi.Vivaldi": "title", "company.thebrowser.Browser": "title", "com.apple.Safari": "name",
    ]

    /// The window, matched by its number (else title and position) through Accessibility:
    /// unminimised, main, raised. True when found.
    @discardableResult
    private static func raise(_ window: SwitcherModel.Item) -> Bool {
        let element = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
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
        func number(_ ax: AXUIElement) -> CGWindowID? {
            var id: CGWindowID = 0
            return windowNumber.flatMap { $0(ax, &id) == .success ? id : nil }
        }
        guard let match = windows.first(where: { number($0) == window.id })
            ?? windows.first(where: { title($0) == window.title && origin($0).map { abs($0.x - window.frame.minX) < 2 && abs($0.y - window.frame.minY) < 2 } ?? false }) else { return false }
        AXUIElementSetAttributeValue(match, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(match, kAXRaiseAction as CFString)
        return true
    }

    /// A browser's window by title, through its own scripting (one Automation prompt per browser).
    private static func raiseInBrowser(_ window: SwitcherModel.Item, bundleID: String) {
        guard let property = scriptable[bundleID] else { return }
        let title = window.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application id \"\(bundleID)\" to set index of (first window whose \(property) is \"\(title)\") to 1"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { Log.app.error("Switcher: browser didn't bring the window forward: \(error, privacy: .public)") }
        else { Log.app.notice("Switcher: asked the browser for its window") }
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

    /// Every app's windows on `screen`, any Space, minimised too, in macOS's front-to-back order —
    /// from Core Graphics' own list, a few milliseconds (ScreenCaptureKit's took ~150 ms before the
    /// switcher could show: "it takes a while", user's report, 2026-11-03). Titled windows are real
    /// ones; untitled ones are apps' helpers.
    func load(on screen: NSScreen, backwards: Bool) async {
        let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let primary = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let area = CGRect(x: screen.frame.minX, y: primary - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        let own = ProcessInfo.processInfo.processIdentifier
        let candidates = list.compactMap { info -> (WindowSwitch.Window, CGRect)? in
            guard let id = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Double] else { return nil }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard area.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
            return (WindowSwitch.Window(id: id, pid: pid, layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                        width: frame.width, height: frame.height, title: title), frame)
        }
        let kept = Set(WindowSwitch.eligible(candidates.map(\.0), own: own).map(\.id))
        // Most recently used first (`WindowRecency`); windows not used since launch after, in
        // macOS's order — which mixes Spaces' stacking orders ("a Chrome window ahead of the
        // one just used", 2026-11-03).
        WindowRecency.shared.noteFront()
        let rank = WindowRecency.shared.rank
        let ordered = candidates.filter { kept.contains($0.0.id) }.enumerated()
            .sorted { (rank[$0.element.0.id] ?? Int.max, $0.offset) < (rank[$1.element.0.id] ?? Int.max, $1.offset) }.map(\.element)
        windows = ordered.compactMap { window, frame in
            guard let app = NSRunningApplication(processIdentifier: window.pid), app.activationPolicy == .regular else { return nil }
            return Item(id: window.id, pid: window.pid, title: window.title, appName: app.localizedName ?? "", icon: app.icon, frame: frame)
        }
        // The desktop, last (user's ask, 2026-11-02: "why is desktop not shown"): its wallpaper as
        // its picture; choosing it clears the windows away, as Mission Control's show desktop does.
        windows.append(Item(id: 0, pid: 0, title: "Desktop", appName: "Desktop",
                            icon: NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app"), frame: screen.frame))
        wallpaper = NSWorkspace.shared.desktopImageURL(for: screen)
        selected = WindowSwitch.first(count: windows.count, backwards: backwards)
    }


    func move(backwards: Bool) { selected = WindowSwitch.step(selected, count: windows.count, backwards: backwards) }

    /// Each window's picture, small, as they come.
    @ObservationIgnored private var wallpaper: URL?

    /// Each window's picture, what it shows now, on any Space (the window server's own capture,
    /// `WindowPictures.capture(id:)`: "the user needs to see what each window is displaying",
    /// 2026-11-03); the last one kept, then ScreenCaptureKit, where that fails. The desktop's
    /// wallpaper, small, after the switcher is up (a full-size one held it back).
    func loadThumbnails() async {
        for index in windows.indices where windows[index].id != 0 {
            let id = windows[index].id
            let picture = await Task.detached(priority: .userInitiated) { WindowPictures.capture(id: id) }.value
            if let picture { WindowPictures.shared.keep(picture, for: id) }
            if windows.indices.contains(index), windows[index].id == id { windows[index].thumbnail = picture ?? WindowPictures.shared.picture(of: id) }
        }
        if let wallpaper, let index = windows.firstIndex(where: { $0.id == 0 }) {
            windows[index].thumbnail = await Task.detached(priority: .utility) { WindowPictures.small(wallpaper) }.value
        }
        guard windows.contains(where: { $0.thumbnail == nil && $0.id != 0 }),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
        for index in windows.indices where windows[index].thumbnail == nil {
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
                MainActor.assumeIsolated {
                    self?.soon()
                    WindowRecency.shared.noteFront()
                }
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

    /// A window's picture as it is now, on any Space or minimised, through the window server's
    /// own capture (SkyLight's `CGSHWCaptureWindowList`, private — what AltTab uses; looked up at
    /// run time like the brightness calls, so a macOS without it falls back to ScreenCaptureKit).
    private typealias Connection = @convention(c) () -> Int32
    private typealias CaptureList = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?
    nonisolated(unsafe) private static let windowServer: (connection: Connection, capture: CaptureList)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(handle, "CGSMainConnectionID"), let capture = dlsym(handle, "CGSHWCaptureWindowList") else { return nil }
        return (unsafeBitCast(connection, to: Connection.self), unsafeBitCast(capture, to: CaptureList.self))
    }()

    nonisolated static func capture(id: UInt32) -> NSImage? {
        guard let windowServer else { return nil }
        var window = id
        // Ignore the global clip shape (1 << 11), at the window's nominal resolution (1 << 9).
        guard let list = windowServer.capture(windowServer.connection(), &window, 1, (1 << 11) | (1 << 9))?.takeRetainedValue() as? [CGImage],
              let image = list.first, image.width > 1, image.height > 1 else { return nil }
        return small(image)
    }

    /// 360 pt wide (at 2×), so a switcher full of them stays light.
    nonisolated static func small(_ image: CGImage) -> NSImage? {
        let width = 720, height = max(1, Int(Double(image.height) * 720 / Double(image.width)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: width / 2, height: height / 2)) }
    }

    nonisolated static func small(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 720] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
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

/// Windows by how recently they were used (user's report, 2026-11-03): the front window noted on
/// every app or Space switch and as the switcher opens, and each one the switcher brings forward.
/// Memory only, the latest 200.
@MainActor
final class WindowRecency {
    static let shared = WindowRecency()
    private var order: [UInt32] = []

    /// Window number → place, 0 the latest.
    var rank: [UInt32: Int] { Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first }) }

    func used(_ window: UInt32) {
        guard window != 0 else { return }
        order.removeAll { $0 == window }
        order.insert(window, at: 0)
        if order.count > 200 { order.removeLast(order.count - 200) }
    }

    /// The front app's top titled window, on screen now.
    func noteFront() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if let top = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
            && !(($0[kCGWindowName as String] as? String) ?? "").isEmpty }), let id = top[kCGWindowNumber as String] as? UInt32 {
            used(id)
        }
    }
}
