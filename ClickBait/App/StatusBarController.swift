import AppKit

/// Owns the menu bar icon and its menu. Until the overlay bubble exists (step 7),
/// the icon and the menu's first line are where ClickBait shows its state.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private static let hint = "Hold ⌃⌥ to ask · tap ⌥⌘ to explain highlighted text · double-tap ⌥⌘ to type"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
    private let revealCaptureItem = NSMenuItem(title: "Reveal Last Capture", action: nil, keyEquivalent: "")
    private let heardItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let answerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let backgroundCapsulesItem = NSMenuItem(title: "Background ClickBaits", action: nil, keyEquivalent: "")
    private let backgroundCapsulesMenu = NSMenu()
    private let internetItem = NSMenuItem(title: "Internet: off 🔒", action: nil, keyEquivalent: "")
    private let recentItem = NSMenuItem(title: "Recent Searches", action: nil, keyEquivalent: "")
    private let notchItem = NSMenuItem(title: "Notch Panel", action: nil, keyEquivalent: "")
    private let volumeHUDItem = NSMenuItem(title: "Volume in the Notch", action: nil, keyEquivalent: "")
    private let spotifyArtItem = NSMenuItem(title: "Spotify Covers", action: nil, keyEquivalent: "")
    /// Turns the notch panel on or off (`NotchController`).
    var onToggleNotch: ((Bool) -> Void)?
    private let recentMenu = NSMenu()
    private let settings: AppSettings
    private let onOpenPermissions: () -> Void
    private let onDebugCapsuleTest: () -> Void
    private let onShowCapsule: (UUID) -> Void
    private var backgroundEntries: [BackgroundJobs.Entry] = []

    init(settings: AppSettings, onOpenPermissions: @escaping () -> Void,
         onDebugCapsuleTest: @escaping () -> Void = {}, onShowCapsule: @escaping (UUID) -> Void = { _ in }) {
        self.settings = settings
        self.onOpenPermissions = onOpenPermissions
        self.onDebugCapsuleTest = onDebugCapsuleTest
        self.onShowCapsule = onShowCapsule
        super.init()

        backgroundCapsulesMenu.delegate = self
        backgroundCapsulesItem.submenu = backgroundCapsulesMenu
        recentItem.submenu = recentMenu
        statusItem.menu = makeMenu()
        settings.internet.onChange = { [weak self] in self?.showInternetMode() }
        showInternetMode()
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
        if menu === backgroundCapsulesMenu { rebuildBackgroundCapsulesMenu() }
    }

    func updateBackgroundJobs(_ entries: [BackgroundJobs.Entry]) {
        // Streamed words change nothing the menu lists: rebuild only for new, gone or
        // finished jobs.
        let listed = { (list: [BackgroundJobs.Entry]) in list.map { "\($0.id) \($0.job.status)" } }
        let changed = listed(entries) != listed(backgroundEntries)
        backgroundEntries = entries
        guard changed else { return }
        backgroundCapsulesItem.isEnabled = !entries.isEmpty
        rebuildBackgroundCapsulesMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        internetItem.action = #selector(toggleInternet)
        internetItem.target = self
        internetItem.toolTip = "Internet Mode: free lookups when you ask (only search words leave your Mac). Off every time ClickBait starts."
        menu.addItem(internetItem)
        menu.addItem(.separator())
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
        backgroundCapsulesItem.isEnabled = false
        menu.addItem(backgroundCapsulesItem)
        menu.addItem(recentItem)
        let remembered = item("Remembered…", action: #selector(openRemembered), key: "")
        remembered.toolTip = "What you asked ClickBait to remember, one line each. Edit or delete freely."
        menu.addItem(remembered)
        let saved = item("Saved Answers…", action: #selector(openSavedAnswers), key: "")
        saved.toolTip = "Answers you saved from the chat, as text files."
        menu.addItem(saved)
        notchItem.action = #selector(toggleNotch)
        notchItem.target = self
        notchItem.state = settings.notchPanelEnabled ? .on : .off
        notchItem.toolTip = "A small panel at the notch: agents, modes, music, a note, clock and stats. Rest the pointer on the notch to open it."
        menu.addItem(notchItem)
        volumeHUDItem.action = #selector(toggleVolumeHUD)
        volumeHUDItem.target = self
        volumeHUDItem.state = settings.notchVolumeHUD ? .on : .off
        volumeHUDItem.toolTip = "The volume keys show their level in the notch instead of macOS's. Off: macOS's HUD as always."
        menu.addItem(volumeHUDItem)
        let artMenu = NSMenu()
        for (title, always) in [("Always", true), ("Only with Internet Mode 🌐", false)] {
            let choice = NSMenuItem(title: title, action: #selector(chooseSpotifyArt(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = always
            choice.state = settings.spotifyArtworkAlways == always ? .on : .off
            artMenu.addItem(choice)
        }
        spotifyArtItem.submenu = artMenu
        spotifyArtItem.toolTip = "Spotify's album covers are downloaded from its artwork link (Apple Music's come from your Mac)."
        menu.addItem(spotifyArtItem)
        menu.addItem(.separator())

        #if DEBUG
        menu.addItem(item("Debug: Test Capsule (Local)", action: #selector(runDebugCapsuleTest), key: ""))
        menu.addItem(.separator())
        #endif
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

    @objc private func openPermissions() { onOpenPermissions() }
    @objc private func openRemembered() { MemoryStore.shared.reveal() }
    @objc private func openSavedAnswers() { AnswerArchive.reveal() }
    @objc private func toggleInternet() { settings.internet.toggle() }
    @objc private func chooseSpotifyArt(_ sender: NSMenuItem) {
        guard let always = sender.representedObject as? Bool else { return }
        settings.spotifyArtworkAlways = always
        spotifyArtItem.submenu?.items.forEach { $0.state = ($0.representedObject as? Bool) == always ? .on : .off }
    }

    @objc private func toggleVolumeHUD() {
        settings.notchVolumeHUD.toggle()
        volumeHUDItem.state = settings.notchVolumeHUD ? .on : .off
    }

    @objc private func toggleNotch() {
        let on = !settings.notchPanelEnabled
        notchItem.state = on ? .on : .off
        onToggleNotch?(on)
    }

    /// The title is text and changes only here, when the switch is toggled — never per
    /// state (per-state status-item changes stalled the companion; spec decision 2).
    private func showInternetMode() {
        let on = settings.internet.isOn
        let title = on ? "🌐 ClickBait" : "🔒 ClickBait"
        if statusItem.button?.title != title {
            statusItem.button?.title = title
            statusItem.button?.setAccessibilityLabel(on ? "ClickBait, Internet Mode on" : "ClickBait, Internet Mode off")
        }
        internetItem.title = on ? "Internet: on 🌐" : "Internet: off 🔒"
        internetItem.state = on ? .on : .off
        recentMenu.removeAllItems()
        let recent = settings.internet.recent
        recentItem.isHidden = !on && recent.isEmpty
        if recent.isEmpty {
            let empty = NSMenuItem(title: "Nothing looked up yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        }
        for lookup in recent {
            let item = NSMenuItem(title: lookup.count > 60 ? String(lookup.prefix(59)) + "…" : lookup, action: nil, keyEquivalent: "")
            item.isEnabled = false
            recentMenu.addItem(item)
        }
    }
    @objc private func showCapsule(_ sender: NSMenuItem) {
        guard let idText = sender.representedObject as? String, let id = UUID(uuidString: idText) else { return }
        Log.app.notice("Background capsule selected for recall")
        // Let AppKit finish dismissing the nested status menu before ordering the
        // status-level panel forward; otherwise the menu can cover the recalled card.
        DispatchQueue.main.async { [weak self] in
            self?.onShowCapsule(id)
        }
    }

    private func rebuildBackgroundCapsulesMenu() {
        backgroundCapsulesMenu.removeAllItems()
        guard !backgroundEntries.isEmpty else {
            let empty = NSMenuItem(title: "No background tasks", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            backgroundCapsulesMenu.addItem(empty)
            return
        }

        for entry in backgroundEntries {
            let state: String
            switch entry.job.status {
            case .working: state = "Working"
            case .done: state = "Ready"
            case .failed: state = "Failed"
            case .stopped: state = "Stopped"
            }
            let question = entry.job.question.count > 44
                ? String(entry.job.question.prefix(43)) + "…"
                : entry.job.question
            let item = NSMenuItem(title: "\(state): \(question)", action: #selector(showCapsule(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id.uuidString
            backgroundCapsulesMenu.addItem(item)
        }
    }

    #if DEBUG
    @objc private func runDebugCapsuleTest() { onDebugCapsuleTest() }
    #endif

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
