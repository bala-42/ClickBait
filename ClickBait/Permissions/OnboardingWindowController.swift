import AppKit
import SwiftUI

/// The permissions window: shown on launch while anything is missing (unless the
/// user opts out), and from the menu bar's "Permissions…" item.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let suppressAtLaunchKey = "onboarding.suppressAtLaunch"

    private let permissions: PermissionsManager

    init(permissions: PermissionsManager) {
        self.permissions = permissions
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to ClickBait"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(
            permissions: permissions,
            onDone: { [weak self] in self?.close() }
        ))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var shouldShowAtLaunch: Bool {
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: "onboarding.hasLaunched")
        UserDefaults.standard.set(true, forKey: "onboarding.hasLaunched")
        if isFirstLaunch { return true }
        return !permissions.allGranted && !UserDefaults.standard.bool(forKey: Self.suppressAtLaunchKey)
    }

    func show() {
        permissions.refresh()
        permissions.startPolling()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        permissions.stopPolling()
    }
}

struct OnboardingView: View {
    let permissions: PermissionsManager
    let onDone: () -> Void

    @AppStorage(OnboardingWindowController.suppressAtLaunchKey) private var suppressAtLaunch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ClickBait needs three permissions")
                    .font(.title2.bold())
                Text("Hold Control+Option, ask out loud, and ClickBait points at what to click. Everything runs on your Mac by default.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind, status: permissions.status(of: kind)) {
                        permissions.request(kind)
                    }
                    if kind != PermissionKind.allCases.last {
                        Divider()
                    }
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            Text(footnote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Toggle("Don't show this at launch", isOn: $suppressAtLaunch)
                    .disabled(permissions.allGranted)
                Spacer()
                Button(permissions.allGranted ? "Done" : "Continue Without") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
    }

    private var footnote: String {
        if permissions.allGranted {
            return "All set. Hold Control+Option anywhere and ask a question."
        }
        return "After turning on Screen Recording, macOS may ask you to quit and reopen ClickBait. "
            + "Missing permissions turn features off rather than breaking the app: without Accessibility, "
            + "the hotkey only works while ClickBait is in front and the pointer can't snap to buttons."
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: kind.symbolName)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.headline)
                Text(kind.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if status == .granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(status == .notDetermined ? "Allow…" : "Open Settings…", action: action)
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
    }
}
