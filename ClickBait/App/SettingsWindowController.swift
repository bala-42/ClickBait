import AppKit
import ClickBaitCore
import SwiftUI

/// Hosts the SwiftUI settings view in a regular window. A menu bar app has no main
/// window, so it activates itself before showing this one.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: AppSettings) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClickBait Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
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
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Hotkey") {
                Text("Hold Control+Option, ask your question out loud, then let go.")
                Text("Pressing any other key while holding cancels, so shortcuts like ⌃⌥← still work.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Provider") {
                Text("Provider, model and API key settings arrive in a later step.")
                    .foregroundStyle(.secondary)
            }

            Section {
                BlocklistEditor(blocklist: $settings.blocklist)
            } header: {
                Text("Never look at these apps")
            } footer: {
                Text("While one of these is the frontmost app, ClickBait won't take a screenshot.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Debugging") {
                Toggle("Keep the last screenshot and recording", isOn: $settings.keepDebugCaptures)
                    .onChange(of: settings.keepDebugCaptures) { _, keep in
                        if !keep { DebugCaptureStore.deleteAll() }
                    }
                Text("Saved to a temporary folder (menu bar → Reveal Last Capture) and deleted when you turn this off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 520)
    }
}

private struct BlocklistEditor: View {
    @Binding var blocklist: AppBlocklist

    var body: some View {
        ForEach(blocklist.apps) { app in
            HStack {
                VStack(alignment: .leading) {
                    Text(app.name)
                    Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    blocklist.remove(bundleID: app.bundleID)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(app.name)")
            }
        }

        HStack {
            Menu("Add Running App") {
                ForEach(addableApps, id: \.bundleID) { app in
                    Button(app.name) { blocklist.add(app) }
                }
            }
            .fixedSize()
            Spacer()
            Button("Restore Defaults") { blocklist = .defaults }
        }
    }

    private var addableApps: [BlockedApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> BlockedApp? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
                return BlockedApp(bundleID: id, name: app.localizedName ?? id)
            }
            .filter { !blocklist.isBlocked(bundleID: $0.bundleID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
