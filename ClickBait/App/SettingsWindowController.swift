import AppKit
import SwiftUI

/// Hosts the SwiftUI settings view in a regular window. A menu bar app has no main
/// window, so it activates itself before showing this one.
@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClickBait Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Hotkey") {
                Text("Hold Control+Option, ask your question out loud, then let go.")
            }
            Section("Provider") {
                Text("Provider, model and API key settings arrive in a later step.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 360)
    }
}
