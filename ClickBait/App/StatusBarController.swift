import AppKit

/// Owns the menu bar icon and its menu. Until the overlay bubble exists (step 7),
/// the icon and the menu's first line are where ClickBait shows its state.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private static let hint = "Hold ⌃⌥ to ask · tap ⌥⌘ to explain highlighted text · double-tap ⌥⌘ to type"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
    private let revealCaptureItem = NSMenuItem(title: "Reveal Last Capture", action: nil, keyEquivalent: "")
    private let heardItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let answerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settings: AppSettings
    private let onOpenSettings: () -> Void
    private let onOpenPermissions: () -> Void

    init(settings: AppSettings, onOpenSettings: @escaping () -> Void, onOpenPermissions: @escaping () -> Void) {
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        self.onOpenPermissions = onOpenPermissions
        super.init()

        statusItem.menu = makeMenu()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "ClickBait")
            button.image?.isTemplate = true
        }
        update(for: .idle)
    }

    func update(for state: AskState) {
        // Only the menu's status line changes; the menu-bar icon stays the same (the
        // companion shows the state): changing it waited on the window server each time
        // and froze the companion (seen in a sample).
        statusLine.title = switch state {
        case .idle: Self.hint
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .speaking: "Speaking…"
        case .error(let message): message
        }
    }

    /// Shows the last transcript until the overlay bubble exists (step 7).
    func showHeard(_ transcript: String) {
        let shown = transcript.count > 80 ? transcript.prefix(79) + "…" : Substring(transcript)
        heardItem.title = "Heard: “\(shown)”"
        heardItem.isHidden = false
    }

    /// Shows the spoken answer and where it points until the overlay exists (step 7).
    func showAnswer(_ speech: String, pointers: [String]) {
        let shown = speech.count > 100 ? speech.prefix(99) + "…" : Substring(speech)
        let pointing = pointers.isEmpty ? "" : "  → " + pointers.joined(separator: ", ")
        answerItem.title = "Answer: \(shown)\(pointing)"
        answerItem.isHidden = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        revealCaptureItem.isHidden = !settings.keepDebugCaptures
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        heardItem.isEnabled = false
        heardItem.isHidden = true
        menu.addItem(heardItem)
        answerItem.isEnabled = false
        answerItem.isHidden = true
        menu.addItem(answerItem)
        menu.addItem(.separator())

        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(item("Permissions…", action: #selector(openPermissions), key: ""))
        revealCaptureItem.action = #selector(revealLastCapture)
        revealCaptureItem.target = self
        menu.addItem(revealCaptureItem)
        menu.addItem(.separator())
        menu.addItem(item("About ClickBait", action: #selector(openAbout), key: ""))
        menu.addItem(item("Quit ClickBait", action: #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSettings() { onOpenSettings() }
    @objc private func openPermissions() { onOpenPermissions() }

    @objc private func revealLastCapture() {
        let directory = DebugCaptureStore.directory
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            NSSound.beep()
        }
    }

    @objc private func openAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
