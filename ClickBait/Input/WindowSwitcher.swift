import AppKit
import ApplicationServices
import ClickBaitCore
import OSLog
import ScreenCaptureKit
import SwiftUI

/// ⌥⇥ window switching (user's ask, 2026-11-02, after AltTab, no AltTab code): hold ⌥, press ⇥ —
/// the windows on this Space as live thumbnails, front to back, the one behind the front
/// selected; ⇥ / ⇧⇥ / ← → move; ⌥ let go (or ↩, or a click) brings it forward; Esc cancels.
/// Thumbnails come from ScreenCaptureKit (Screen Recording, which ClickBait has); bringing a
/// window forward uses Accessibility.
@MainActor
final class WindowSwitcher {
    static let shared = WindowSwitcher()
    var enabled: () -> Bool = { true }
    private var panel: NSPanel?
    private let model = SwitcherModel()
    var showing: Bool { panel != nil }

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
        case .released: if showing { choose() }; return false
        }
    }

    private func open(backwards: Bool) {
        model.load(backwards: backwards)
        guard !model.windows.isEmpty else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
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

    /// The app forward, then its window matched by title and frame, raised as main.
    static func bringForward(_ window: SwitcherModel.Item) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        app.activate()
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
        let match = windows.first { title($0) == window.title && origin($0).map { abs($0.x - window.frame.minX) < 2 && abs($0.y - window.frame.minY) < 2 } ?? false }
            ?? windows.first { title($0) == window.title } ?? windows.first
        guard let match else { return }
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

    func load(backwards: Bool) {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let own = ProcessInfo.processInfo.processIdentifier
        let raw = list.compactMap { info -> (WindowSwitch.Window, CGRect, String)? in
            guard let id = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = info[kCGWindowBounds as String] as? [String: Double] else { return nil }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            let title = info[kCGWindowName as String] as? String ?? ""
            return (WindowSwitch.Window(id: id, pid: pid, layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                        width: frame.width, height: frame.height, title: title), frame, title)
        }
        let kept = Set(WindowSwitch.eligible(raw.map(\.0), own: own).map(\.id))
        windows = raw.filter { kept.contains($0.0.id) }.compactMap { window, frame, title in
            guard let app = NSRunningApplication(processIdentifier: window.pid), app.activationPolicy == .regular else { return nil }
            return Item(id: window.id, pid: window.pid, title: title, appName: app.localizedName ?? "", icon: app.icon, frame: frame)
        }
        selected = WindowSwitch.first(count: windows.count, backwards: backwards)
    }

    func move(backwards: Bool) { selected = WindowSwitch.step(selected, count: windows.count, backwards: backwards) }

    /// Each window's picture, small, as they come.
    func loadThumbnails() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        for index in windows.indices {
            guard let window = content.windows.first(where: { $0.windowID == windows[index].id }) else { continue }
            let configuration = SCStreamConfiguration()
            let scale = 360 / max(window.frame.width, 1)
            configuration.width = Int(window.frame.width * scale * 2)
            configuration.height = Int(window.frame.height * scale * 2)
            configuration.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration),
               windows.indices.contains(index), windows[index].id == window.windowID {
                windows[index].thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
            }
        }
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
                                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06))
                            }
                        }
                        .frame(width: cardWidth - 16, height: 120)
                        if let icon = window.icon {
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
