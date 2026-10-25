import AppKit
import ClickBaitCore
import SwiftUI

/// Owns the menu bar icon and its menu. Until the overlay bubble exists (step 7),
/// the icon and the menu's first line are where ClickBait shows its state.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private static let hint = "Hold ⌃⌥ to ask · tap ⌥⌘ to explain highlighted text · double-tap ⌥⌘ to type"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
    private let revealCaptureItem = NSMenuItem(title: "Reveal Last Capture", action: nil, keyEquivalent: "")
    private let heardItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let modelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// How the answering model is doing; read each time the menu opens (set by the app delegate).
    var checkHealth: @MainActor () async -> HealthLadder.Item? = { nil }
    private let answerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let backgroundCapsulesItem = NSMenuItem(title: "Background ClickBaits", action: nil, keyEquivalent: "")
    private let backgroundCapsulesMenu = NSMenu()
    private let internetItem = NSMenuItem(title: "Internet: off 🔒", action: nil, keyEquivalent: "")
    private let recentItem = NSMenuItem(title: "Recent Searches", action: nil, keyEquivalent: "")
    private let notchItem = NSMenuItem(title: "Notch Panel", action: nil, keyEquivalent: "")
    private let volumeHUDItem = NSMenuItem(title: "Volume in the Notch", action: nil, keyEquivalent: "")
    private let spotifyArtItem = NSMenuItem(title: "Spotify Covers", action: nil, keyEquivalent: "")
    private let soundsItem = NSMenuItem(title: "Sounds", action: nil, keyEquivalent: "")
    private let greetingsItem = NSMenuItem(title: "Greetings", action: nil, keyEquivalent: "")
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
        // The notch's Settings can change these too.
        notchItem.state = settings.notchPanelEnabled ? .on : .off
        volumeHUDItem.state = settings.notchVolumeHUD ? .on : .off
        soundsItem.state = settings.soundCues ? .on : .off
        greetingsItem.state = settings.greetings ? .on : .off
        spotifyArtItem.submenu?.items.forEach { $0.state = ($0.representedObject as? Bool) == settings.spotifyArtworkAlways ? .on : .off }
        if menu === statusItem.menu {
            Task { @MainActor [weak self] in
                guard let self else { return }
                showHealth(await checkHealth())
            }
        }
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
        modelItem.isEnabled = false
        showHealth(nil)
        menu.addItem(modelItem)
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
        let notes = item("Notes Folder…", action: #selector(openNotes), key: "")
        notes.toolTip = "Your own .md notes. Lines that fit a question go to the local model."
        menu.addItem(notes)
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
        soundsItem.action = #selector(toggleSounds)
        soundsItem.target = self
        soundsItem.state = settings.soundCues ? .on : .off
        soundsItem.toolTip = "A soft sound when a background ClickBait is done, and when ClickBait needs your yes."
        menu.addItem(soundsItem)
        greetingsItem.action = #selector(toggleGreetings)
        greetingsItem.target = self
        greetingsItem.state = settings.greetings ? .on : .off
        greetingsItem.toolTip = "A hello by the cursor on the first wake of the day, or after a long time away."
        menu.addItem(greetingsItem)
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

    /// The background ClickBaits the menu lists (the notch's Settings lists them too).
    var backgroundJobs: [BackgroundJobs.Entry] { backgroundEntries }

    @objc func openPermissions() { onOpenPermissions() }
    @objc private func openRemembered() { MemoryStore.shared.reveal() }
    @objc private func openNotes() { MemoryStore.shared.revealNotes() }
    @objc private func openSavedAnswers() { AnswerArchive.reveal() }
    @objc private func toggleInternet() { settings.internet.toggle() }
    @objc private func chooseSpotifyArt(_ sender: NSMenuItem) {
        guard let always = sender.representedObject as? Bool else { return }
        settings.spotifyArtworkAlways = always
        spotifyArtItem.submenu?.items.forEach { $0.state = ($0.representedObject as? Bool) == always ? .on : .off }
    }

    @objc private func toggleSounds() {
        settings.soundCues.toggle()
        soundsItem.state = settings.soundCues ? .on : .off
    }

    @objc private func toggleGreetings() {
        settings.greetings.toggle()
        greetingsItem.state = settings.greetings ? .on : .off
    }

    @objc private func toggleVolumeHUD() {
        settings.notchVolumeHUD.toggle()
        volumeHUDItem.state = settings.notchVolumeHUD ? .on : .off
    }

    @objc private func toggleNotch() { setNotch(!settings.notchPanelEnabled) }

    func setNotch(_ on: Bool) {
        notchItem.state = on ? .on : .off
        onToggleNotch?(on)
    }

    /// The menu bar shows the companion's triangle, white like the other icons, tilted as on
    /// screen (user's ask, 2026-10-25); Internet Mode shows in the menu and to VoiceOver.
    /// Changes only here, when the switch is toggled — never per state (per-state
    /// status-item changes stalled the companion; spec decision 2).
    private func showInternetMode() {
        let on = settings.internet.isOn
        if statusItem.button?.image == nil {
            statusItem.button?.title = ""
            statusItem.button?.image = Self.triangleIcon
        }
        statusItem.button?.setAccessibilityLabel(on ? "ClickBait, Internet Mode on" : "ClickBait, Internet Mode off")
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
    @objc private func showCapsuleItem(_ sender: NSMenuItem) {
        guard let idText = sender.representedObject as? String, let id = UUID(uuidString: idText) else { return }
        showCapsule(id)
    }

    func showCapsule(_ id: UUID) {
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
            let state = SettingsView.status(entry.job.status)
            let question = entry.job.question.count > 44
                ? String(entry.job.question.prefix(43)) + "…"
                : entry.job.question
            let item = NSMenuItem(title: "\(state): \(question)", action: #selector(showCapsuleItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id.uuidString
            backgroundCapsulesMenu.addItem(item)
        }
    }

    #if DEBUG
    @objc func runDebugCapsuleTest() { onDebugCapsuleTest() }
    #endif

    @objc func revealLastCapture() {
        let directory = DebugCaptureStore.directory
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            NSSound.beep()
        }
    }

    @objc func openAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.credits])
    }

    /// The licence and the bundled font's credit (its OFL licence asks for the credit).
    static let credits: NSAttributedString = {
        let text = """
            ClickBait is free software under the GNU AGPL-3.0.
            Runs on your Mac with a local model; nothing leaves it except Internet Mode lookups.

            Volume HUD lettering: Press Start 2P, © 2012 The Press Start 2P Project Authors (cody@zone38.net), \
            licensed under the SIL Open Font License 1.1.
            App icon background: the Hubble Ultra Deep Field. Image: NASA, ESA, and S. Beckwith (STScI).
            """
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ])
    }()

    /// The companion's triangle (`EquilateralTriangle`) at its resting tilt, as a template
    /// image so macOS draws it white or black to match the menu bar.
    static let triangleIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let side: CGFloat = 13
            let shape = EquilateralTriangle().path(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
            let turn = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: CompanionTriangle.restingAngle * .pi / 180)
                .translatedBy(x: -rect.midX, y: -rect.midY)
            NSColor.black.setFill()
            NSBezierPath(cgPath: shape.applying(turn).cgPath).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ClickBait"
        return image
    }()

    @objc func quit() { NSApp.terminate(nil) }

    private func showHealth(_ health: HealthLadder.Item?) {
        let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: NSColor(health?.color ?? .gray)])
        title.append(NSAttributedString(string: health?.words ?? "Checking…"))
        modelItem.attributedTitle = title
        // A permission that's off: the line opens the Permissions window.
        if case .permissionOff = health {
            modelItem.action = #selector(openPermissions)
            modelItem.target = self
        } else {
            modelItem.action = nil
        }
    }
}

/// ClickBait's health as the menu and the notch show it: a dot and a few words.
extension HealthLadder.Item {
    var words: String {
        switch self {
        case .ready: "Model ready"
        case .modelAsleep: "Model asleep, the first answer is slower"
        case .modelMissing(let model): "\(model) isn't installed"
        case .ollamaOff: "Ollama isn't running"
        case .permissionOff(let permission): "\(permission) is off: click to fix"
        }
    }

    /// For the notch's one short line.
    var shortWords: String {
        switch self {
        case .ready: "ready"
        case .modelAsleep: "model asleep"
        case .modelMissing: "model not installed"
        case .ollamaOff: "Ollama isn't running"
        case .permissionOff(let permission): "\(permission) off"
        }
    }

    /// Ready is Azure (idle), asleep grey, a problem Wine.
    var color: Color {
        switch self {
        case .ready: CompanionTone.idle.color
        case .modelAsleep: Color(white: 0.55)
        case .ollamaOff, .modelMissing, .permissionOff: CompanionTone.problem
        }
    }
}
