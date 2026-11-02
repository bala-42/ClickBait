import ClickBaitCore
import ScriptingBridge
import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NSApplication.delegate is weak, so the delegate is kept alive here.
    private static var shared: AppDelegate?

    private let settings = AppSettings()
    private let permissions = PermissionsManager()
    private lazy var speech = SpeechModelManager(settings: settings)
    private lazy var coordinator = AskCoordinator(settings: settings, speech: speech)
    private lazy var hotkey = HotkeyMonitor { [weak self] event in
        switch event {
        case .dictatePressed, .dictateReleased, .dictateCancelled: self?.dictation.handle(event)
        default: self?.coordinator.handle(event)
        }
    }
    private lazy var dictation = DictationController(coordinator: coordinator, overlay: overlay)
    private var statusBar: StatusBarController?
    private let overlay = OverlayController()
    private lazy var greeter = Greeter(settings: settings, overlay: overlay)
    private lazy var capsules = CapsuleController()
    private lazy var notch = NotchController(settings: settings, speech: speech, speaker: coordinator.speaker)
    /// "Remember with ClickBait" in the Services menu.
    private let servicesProvider = ServicesProvider()
    /// Blue highlights and arrows on screen (`GuidanceController`).
    private lazy var guidance = GuidanceController()
    /// Done jobs whose result pill has been shown (or is waiting to be).
    private var announcedJobs: Set<UUID> = []
    /// The last done pill, so the next one says something else.
    private var lastDoneLine: String?
    private var askingSuggestions: Set<UUID> = []
    private let backgroundJobs = BackgroundJobs()
    private let chat = ChatController()
    /// The notch's own Ask conversation, separate from the overlay chat.
    private let notchChat = NotchChat()
    private let agents = AgentWatcher()
    /// Shelf archives already offered a peek: never asked twice.
    private var offeredPeeks: Set<URL> = []
    private let confirm = ConfirmController()
    private let escape = InputInterceptor()
    /// The "let's see! / later." pill is up.
    private var readyPillShown = false
    /// Where the companion was at the last hotkey press: the chat's place.
    private var invokedPoint: CGPoint?
    private lazy var tutorial = TutorialController(overlay: overlay)
    private lazy var morning = MorningBrief(settings: settings)
    private lazy var onboardingWindow = OnboardingWindowController(permissions: permissions, settings: settings, speech: speech)

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        // A regular app (user's ask, 2026-10-25): in the Dock while it runs, ⌘-Tab, its own
        // menus when in front. It was a menu-bar-only accessory.
        app.setActivationPolicy(.regular)
        app.run()
    }

    /// Clicking ClickBait in the Dock: its window (setup, or "you're set" with the shortcuts).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        onboardingWindow.show()
        return false
    }

    // The app menu's actions (the application passes them to its delegate).
    @objc func showAbout() { statusBar?.openAbout() }
    @objc func showSetup() { onboardingWindow.show() }

    /// The menus a regular app has when in front: ClickBait's, Edit (so ⌘C, ⌘V and ⌘A work in
    /// its text fields) and Window.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            items.forEach(submenu.addItem)
            holder.submenu = submenu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        menu("ClickBait", [
            item("About ClickBait", #selector(AppDelegate.showAbout), ""),
            item("Setup and Permissions…", #selector(AppDelegate.showSetup), ","),
            .separator(),
            item("Hide ClickBait", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit ClickBait", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }

    /// Hosting the UI smoke tests (ClickBaitTests): nothing starts, and a running ClickBait is
    /// left alone (no other instance is quit, no model unloaded).
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Lets Ollama free the models it kept loaded for ClickBait.
    func applicationWillTerminate(_ notification: Notification) {
        AppVolumeMixer.shared.stopAll()  // every app's own sound back, untapped
        guard !Self.isHostingTests else { return }
        backgroundJobs.removeAll()
        capsules.removeAll()
        settings.makeProvider().unload()
    }

    /// Smart search's index: a first pass a minute after launch, then every 30 minutes, at
    /// low priority. Fetches the search model too if this Mac's brain came before it.
    private func startSearchIndex() {
        let settings = settings
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(60))
            if let installed = await OllamaSetup.installedModels(),
               !installed.contains(where: { $0.hasPrefix(Embedder.model) }) {
                try? await OllamaSetup.pull(Embedder.model) { _ in }
            }
            while !Task.isCancelled {
                let options = await MainActor.run { settings.visionOptions }
                await SearchIndex.shared.refresh(options)
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
        Self.watchPictures(settings)
    }

    /// Folder changes update Vision Memory within seconds (`PictureWatcher`).
    static func watchPictures(_ settings: AppSettings) {
        PictureWatcher.shared.watch(settings.visionFolders) {
            let options = settings.visionOptions
            Task.detached(priority: .background) { await SearchIndex.shared.refresh(options, quick: true) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        NSApp.mainMenu = Self.mainMenu()
        dictation.noteTarget = { [weak self] in
            guard let note = self?.notch.model.note, note.isTyping else { return nil }
            return note.textView
        }
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
        #if DEBUG
        if SelfTest.runBeforeLaunch(settings: settings) { return }  // every switch: SelfTest
        #endif
        terminateOtherInstances()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.app.notice("ClickBait \(version, privacy: .public) launched")
        #if DEBUG
        StallTrap.shared.start()
        #endif

        let statusBar = StatusBarController(
            settings: settings,
            onOpenPermissions: { [weak self] in self?.onboardingWindow.show() },
            onDebugCapsuleTest: { [weak self] in
                #if DEBUG
                self?.coordinator.runDebugCapsuleTest()
                #endif
            },
            onShowCapsule: { [weak self] in self?.capsules.expand($0) }
        )
        self.statusBar = statusBar
        statusBar.onToggleNotch = { [weak self] in self?.notch.setEnabled($0) }
        notch.model.menuBar = statusBar
        // Nil is success: never `?? reason` (it turned every start into "isn't ready" while the
        // microphone recorded on, with no stop button: 2026-10-24, as the dock's once did).
        notch.model.voiceStart = { [weak self] in
            guard let self else { return "ClickBait isn't ready." }
            return coordinator.startCardRecording()
        }
        notch.model.voiceFinish = { [weak self] in
            guard let self else { return .failure(AskCoordinator.CardVoiceError(message: "ClickBait isn't ready.")) }
            return await coordinator.finishCardRecording()
        }
        notch.model.voiceCancel = { [weak self] in self?.coordinator.cancelCardRecording() }
        coordinator.onCardRecordingDropped = { [weak self] in self?.notch.model.voiceDrops += 1 }
        notch.model.micLevel = { [weak self] in self?.coordinator.cardMicrophoneLevel ?? 0 }
        notch.model.permissions = permissions
        escape.onVolumeKey = { [weak self] key, fine in self?.notch.handleVolumeKey(key, fine: fine) ?? false }
        escape.onBrightnessKey = { [weak self] key, fine in self?.notch.handleBrightnessKey(key, fine: fine) ?? false }
        overlay.start()
        greeter.start(helloAtLaunch: true)  // by the cursor too, not only the notch's (user's ask, 2026-10-23)
        // Morning cards: a done "Good morning" card in the dock, its cards as the suggestions.
        morning.present = { [weak self] text in self?.notch.showMorning(text) ?? false }
        morning.start()
        startSearchIndex()
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLICKBAIT_TEST_GREETING"] != nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.overlay.showGreeting(Greeting.line(at: Date(), recent: []).text)
            }
        }
        #endif
        notch.model.mood = { [overlay] in overlay.model.beanMood }
        overlay.onGuide = { [weak self] in self?.notch.makeRoom() }
        // The worst thing wrong right now (`HealthLadder`), read each time the menu or the notch opens.
        // A permission counts as off only once refused: Microphone not asked yet is asked on first use.
        let checkHealth: @MainActor () async -> HealthLadder.Item? = { [settings, permissions] in
            permissions.refresh()
            let off = [PermissionKind.screenRecording, .accessibility, .microphone]
                .filter { permissions.status(of: $0) == .denied }.map(\.title)
            return HealthLadder.worst(model: await settings.makeProvider().health(), permissionsOff: off)
        }
        notch.model.checkHealth = checkHealth
        statusBar.checkHealth = checkHealth
        // The notch's Ask is its own conversation, kept like the shelf (`NotchChat`); the
        // overlay chats (⌃⌥, ⌥⌘) are separate and never touch it.
        notchChat.brain = { [weak self] in self?.settings.ollamaModel ?? "" }
        notchChat.look = { [weak self] in
            guard let self, CGPreflightScreenCaptureAccess(),
                  let capture = try? await coordinator.capturer.captureDisplayUnderCursor(
                      excluding: settings.blocklist, ignoreClickBait: settings.ignoreNotchInCaptures) else { return nil }
            return try? await ScreenshotEncoder.encodeInBackground(capture.image).jpeg
        }
        notchChat.searchSettings = { [weak self] in
            guard let self else { return nil }
            let options = settings.visionOptions
            let why = !settings.visionDescribe ? "Describe multimedia is off"
                : !options.onBattery && VisionOptions.onBatteryPower ? "I read them while the Mac is plugged in" : nil
            return (settings.notchNote, options, why)
        }
        notchChat.model.onClose = { [weak self] in self?.notch.model.tab = .home }  // put away, kept
        // New chat: a fresh Ask, staying on the Ask tab (it went Home: "should just restart ask").
        notchChat.model.onClear = { [weak self] in
            self?.notchChat.clear()
            self?.notch.model.chatting = false
        }
        notch.model.chat = notchChat.model
        notch.model.ask = { [weak self] text in
            guard let self else { return }
            notch.model.chatting = true
            notchChat.send(text)
        }
        notch.start()
        coordinator.backgroundJobs = backgroundJobs
        backgroundJobs.onDone = { [weak self] _ in
            guard let self else { return }
            SoundCues.play(.done, enabled: settings.soundCues)
            // The dock comes out to show it (a follow-up in a card too, which had no pill),
            // then folds away again when left alone (user's ask, 2026-10-25).
            capsules.summon()
        }
        backgroundJobs.onChange = { [weak self] entries in
            self?.capsules.sync(entries)
            self?.statusBar?.updateBackgroundJobs(entries)
            self?.announceFinished(entries)
        }
        capsules.canGoThere = { [weak self] in self.map { !$0.coordinator.isBusy } ?? false }
        capsules.onStop = { [weak self] in self?.backgroundJobs.stop($0) }
        capsules.onDismiss = { [weak self] in self?.backgroundJobs.remove($0) }
        capsules.onLater = { [weak self] in self?.capsules.fold($0) }
        capsules.onGoThere = { [weak self] id in
            guard let self else { return }
            // A file job: "show me!" shows the new files in Finder, and the tile is done with.
            if let made = backgroundJobs.entries.first(where: { $0.id == id })?.madeFiles, !made.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(made)
                backgroundJobs.remove(id)
                return
            }
            // A walkthrough planned in the dock: "show me!" goes there and starts it.
            if let pending = backgroundJobs.entries.first(where: { $0.id == id })?.walkthrough {
                goThere(id) { [weak self] in self?.coordinator.resumeWalkthrough(pending) }
            } else {
                goThere(id)
            }
        }
        capsules.onSeen = { [weak self] id in
            self?.backgroundJobs.markSeen(id)
            self?.suggestNext(for: id)
        }
        capsules.onSuggestion = { [weak self] id, text in
            guard let self else { return }
            let pending = backgroundJobs.entries.first(where: { $0.id == id })?.walkthrough
            // A follow-up chip ("tell me more", a suggested question) carries on in this card's
            // own conversation, its answer in the mini-chat: it used to go back to the window,
            // ask in the main chat and, slow, land in the dock as a new task (user's report,
            // 2026-10-25). The walkthrough and the parts tour still need the window.
            if text != PeelRule.walkthroughResumePrompt, text != PeelRule.suggestedPartsPrompt {
                coordinator.nextTypedIsDetailed = text == PeelRule.tellMorePrompt
                capsules.followUp(id, .tap(.text))
                capsules.followUp(id, .draft(text))
                capsules.followUp(id, .submit)
                return
            }
            goThere(id) { [weak self] in
                guard let self else { return }
                // Its walkthrough was planned in the dock: start it now, back where it was asked.
                if text == PeelRule.walkthroughResumePrompt, let pending { coordinator.resumeWalkthrough(pending); return }
                guard chat.isOpen else { return }
                // Its tour was placed in the dock: play it, no model asked.
                if text == PeelRule.suggestedPartsPrompt, coordinator.playReadyTour() { return }
                coordinator.nextTypedIsDetailed = text == PeelRule.tellMorePrompt
                chat.model.draft = text
                coordinator.nextTypedIsSuggestion = true  // slow → back to the dock
                chat.model.send()  // as if typed: it's a follow-up in that chat
            }
        }
        capsules.onFollowUpSend = { [weak self] id, text in self?.coordinator.askInBackground(text, jobID: id) }
        capsules.onCardVoiceStart = { [weak self] in
            // Nil is success: never `?? reason`, which turned every start into a failure.
            guard let self else { return "ClickBait isn't ready." }
            return coordinator.startCardRecording()
        }
        capsules.onCardVoiceCancel = { [weak self] in self?.coordinator.cancelCardRecording() }
        capsules.cardMicrophoneLevel = { [weak self] in self?.coordinator.cardMicrophoneLevel ?? 0 }
        capsules.onCardVoiceFinish = { [weak self] in
            guard let self else { return .failure(AskCoordinator.CardVoiceError(message: "ClickBait isn't ready.")) }
            return await coordinator.finishCardRecording()
        }
        coordinator.onPeel = { [weak self] job in
            guard let self else { return [] }
            let messages = chat.stash()
            backgroundJobs.setChatMessages(messages, for: job.id)
            let index = backgroundJobs.entries.firstIndex(where: { $0.id == job.id })
            let target = index.flatMap { capsules.slotCenter(forIndex: $0) }
            let tone = job.kind.tone
            overlay.peel(to: target, tone: tone, completion: {})
            return messages
        }
        coordinator.onPeelRefused = { [weak self] in self?.overlay.showShortAnswer("three's a crowd") }
        // Drops on the notch's shelf say how they went in the companion's pill.
        ShelfDrop.say = { [weak self] text, tone in self?.overlay.showJobResult(text, tone: tone, force: true) }
        ShelfDrop.offerPeek = { [weak self] archive in self?.offerPeek(archive) }
        agents.onNotice = { [weak self] notice in self?.showAgentNotice(notice) }
        wireGallery()
        ClipboardHistory.shared.start()
        // The timer bubble's countdown or Pomodoro phase ended: a pill by the cursor.
        NotchTimerClock.shared.onFinish = { [weak self] text, alarm in
            guard let self else { return }
            // Alarms the user set ring whatever the sound-cues switch says.
            switch alarm {
            case .timer: notch.ringAlarm()
            case .pleasant: TimerSounds.ring(.pleasant)
            case .striking: TimerSounds.ring(.striking)
            }
            overlay.showJobResult(text, tone: .idle, force: true)
        }
        startAgentNotices()
        // Every peek opens the archive browser (MacPacker-style), however it was asked for.
        FileActions.onPeek = { archives in archives.first.map(ArchiveBrowser.shared.show) }
        // A shelf hover pill: straight away on that file (the click was the asking); a peek opens
        // the archive browser, the rest go to the dock and come back onto the shelf.
        ShelfDrop.runAction = { [weak self] request, file in
            guard let self else { return }
            Task { @MainActor in
                _ = await self.coordinator.perform(request, speak: false, files: [file], quiet: request.name == "peek")
            }
        }
        coordinator.overlayQuietDone = { [weak self] in
            self?.overlay.endWorking()
            self?.overlay.dismissAnswer()
        }
        TakeMeThere.say = { [weak self] text in self?.overlay.showHoverHint(text) }
        StudioModel.brain = { [weak self] in self?.settings.ollamaModel ?? "" }
        // Studio's prompter shortcuts, only while it's up: ⌃⌘P, ⌃⌘↑ ↓, ⌃⌘← →.
        escape.onPrompterKey = { code in
            let studio = StudioModel.shared
            guard studio.prompting else { return false }
            DispatchQueue.main.async {
                switch code {
                case 35: studio.togglePause()
                case 126: studio.nextCue(-1)
                case 125: studio.nextCue(1)
                case 123: studio.changeSpeed(-6)
                default: studio.changeSpeed(6)
                }
            }
            return true
        }
        // Studio's prompter hears you through the same speech model as dictation.
        VoiceFollower.transcribe = { [weak self] samples, prompt in
            guard let self, speech.isReady else { return nil }
            return try? await speech.transcribe(samples, prompt: prompt)
        }
        #if DEBUG
        // Studio from the outside, for live tests: start or stop the prompter.
        // Smart search from the outside, for live tests: "search:<question>" logs what it finds.
        DistributedNotificationCenter.default().addObserver(forName: .init("org.clickbait.debug.search"), object: nil, queue: .main) { [weak self] note in
            guard let question = note.object as? String else { return }
            MainActor.assumeIsolated {
                guard let self, let request = SmartSearch.request(in: question) else {
                    Log.app.notice("Debug search: not a search question")
                    return
                }
                let options = self.settings.visionOptions
                Task {
                    let found = await SearchIndex.shared.search(request, notchNote: "", options: options)
                    Log.app.notice("Debug search: kind \(request.kind.rawValue, privacy: .public), terms \(request.terms.joined(separator: " "), privacy: .public) → \(found.map { "[\($0.kind.rawValue)] \($0.title)" }.joined(separator: " | "), privacy: .public)")
                }
            }
        }
        // Opens a bubble page ("gallery", "gallery:watch", "timer", "volume"): live tests of fitting.
        DistributedNotificationCenter.default().addObserver(forName: .init("org.clickbait.debug.page"), object: nil, queue: .main) { [weak self] note in
            let parts = (note.object as? String ?? "gallery").split(separator: ":").map(String.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notch.debugOpen(tab: parts[0], page: parts.count > 1 ? parts[1] : nil)
            }
        }
        // The morning greeting now, whatever the day: live tests.
        DistributedNotificationCenter.default().addObserver(forName: .init("org.clickbait.debug.morning"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.morning.check(force: true) }
            }
        }
        // The timer's end without waiting: the ruby notch and a sound ("timer", "pleasant", "striking").
        DistributedNotificationCenter.default().addObserver(forName: .init("org.clickbait.debug.alarm"), object: nil, queue: .main) { note in
            let kind = note.object as? String ?? "timer"
            MainActor.assumeIsolated {
                let alarm: NotchTimerClock.Alarm = kind == "pleasant" ? .pleasant : kind == "striking" ? .striking : .timer
                NotchTimerClock.shared.onFinish?("debug: \(kind)", alarm)
            }
        }
        // Presses the showing card's button ("yes"/"no"): live tests of cards like peek's extract.
        DistributedNotificationCenter.default().addObserver(forName: .init("org.clickbait.debug.card"), object: nil, queue: .main) { [weak self] note in
            let yes = (note.object as? String) == "yes"
            MainActor.assumeIsolated { self?.confirm.debugAnswer(yes) }
        }
        // A watch on the main screen's top-right corner for a word: live tests of Watch.
        DistributedNotificationCenter.default().addObserver(forName: .init("org.clickbait.debug.watch"), object: nil, queue: .main) { [weak self] note in
            guard let word = note.object as? String else { return }
            MainActor.assumeIsolated {
                guard let self, let screen = NSScreen.screens.first else { return }
                // "word" watches the top-right corner (the menu bar); "word@middle" the screen's middle.
                let parts = word.split(separator: "@").map(String.init)
                let area = parts.count > 1
                    ? CGRect(x: screen.frame.midX - 400, y: screen.frame.midY - 150, width: 800, height: 300)
                    : CGRect(x: screen.frame.maxX - 340, y: screen.frame.maxY - 26, width: 340, height: 26)
                ScreenWatcher.shared.start(area: area, rule: .says(parts[0]), blocklist: self.settings.blocklist)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(6))
                    Log.app.notice("Debug watch: reads \(ScreenWatcher.shared.reading.prefix(60), privacy: .public), watching \(ScreenWatcher.shared.watching, privacy: .public)")
                }
            }
        }
        // The shelf's "peek at it?" offer for a file, and an answer to it ("yes"/"no"): live tests.
        DistributedNotificationCenter.default().addObserver(forName: .init("org.clickbait.debug.peekoffer"), object: nil, queue: .main) { [weak self] note in
            guard let path = note.object as? String else { return }
            MainActor.assumeIsolated { self?.offerPeek(URL(fileURLWithPath: path)) }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("org.clickbait.debug.answer"), object: nil, queue: .main) { [weak self] note in
            let yes = (note.object as? String) == "yes"
            MainActor.assumeIsolated { Task { @MainActor in await self?.coordinator.resolvePending(yes) } }
        }
        // An order from the outside ("convert this to mp4"), as if typed: for live dock tests.
        DistributedNotificationCenter.default().addObserver(forName: .init("org.clickbait.debug.order"), object: nil, queue: .main) { [weak self] note in
            guard let text = note.object as? String else { return }
            MainActor.assumeIsolated {
                guard let self, let request = CommandParser.parse(text, allowedShortcuts: []) else { Log.app.notice("Debug order: not an order"); return }
                Task {
                    if let action = self.coordinator.asksFirst(request) {
                        await self.coordinator.handleOrder(action, request: request, speak: false, from: .clearOrder)
                    } else {
                        _ = await self.coordinator.perform(request, speak: false)
                    }
                }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("org.clickbait.debug.studio"), object: nil, queue: .main) { note in
            let command = note.object as? String
            MainActor.assumeIsolated {
                switch command {
                case "stop": StudioModel.shared.stopPrompting()
                case "float": StudioModel.shared.floating.toggle()
                case "shrinktest":
                    // A drag shrinking the prompter, step by step: the window's centre each step.
                    Task { @MainActor in
                        let studio = StudioModel.shared
                        let start = studio.size
                        studio.resizing = true
                        for step in 0...20 {
                            studio.size = CGSize(width: start.width - Double(step) * 10, height: start.height - Double(step) * 4)
                            PrompterController.shared.resize(to: studio.size)
                            try? await Task.sleep(for: .milliseconds(30))
                            if let window = NSApp.windows.filter({ $0.isVisible && $0.level == WindowLayers.notch }).max(by: { $0.frame.height < $1.frame.height }) {
                                Log.app.notice("Studio shrink: width \(Int(studio.size.width), privacy: .public) window \(Int(window.frame.width), privacy: .public) centre \(Int(window.frame.midX), privacy: .public)")
                            }
                        }
                        studio.resizing = false
                        studio.size = start
                        PrompterController.shared.resize(to: start)
                    }
                case "snap":
                    // The prompter windows' live contents, drawn, for checking their shape.
                    for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.level == WindowLayers.notch {
                        if let rep = window.contentView?.sharpRep(scale: 2),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: "/tmp/clickbait-window-\(index).png"))
                        }
                    }
                default: StudioModel.shared.startPrompting()
                }
            }
        }
        #endif
        // Setup's last step: a tapped suggestion is asked for real, in the chat.
        _ = NotificationCenter.default.addObserver(forName: .clickBaitAskFromSetup, object: nil, queue: .main) { [weak self] note in
            guard let question = note.object as? String else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.coordinator.startTypedChat(trigger: "setup")
                self.chat.model.draft = question
                self.chat.model.send()
            }
        }
        coordinator.onQuickEnding = { [weak self] text, tone, immediate in
            guard let self else { return }
            if immediate {
                overlay.showJobResult(text, tone: tone, force: true)
            } else {
                showWhenQuiet(text, tone: tone, for: .seconds(60), while: { true })
            }
        }
        #if DEBUG
        overlay.runBenchmarkIfRequested()
        runChatBenchmarkIfRequested()
        runDockBenchmarkIfRequested()
        runCardVoiceTestIfRequested()
        runNotchVoiceTestIfRequested()
        #if DEBUG
        TestDriver.runIfRequested { [unowned self] in
            TestDriver.Hooks(notch: notch, coordinator: coordinator, overlay: overlay, tutorial: tutorial,
                             backgroundJobs: backgroundJobs, chat: chat, capsules: capsules,
                             goThere: { [weak self] id in self?.capsules.onGoThere?(id) },
                             openSetup: { [weak self] in self?.onboardingWindow.show() })
        }
        #endif
        runRouteBenchIfRequested()
        runGoThereTestIfRequested()
        runMenuTestIfRequested()
        MenuMemory.learnOpenApps()
        #if DEBUG
        runGuidanceTestIfRequested()
        #endif
        if ProcessInfo.processInfo.environment["CLICKBAIT_TEST_NOTCH"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let env = ProcessInfo.processInfo.environment
                Log.app.notice("Notch test: collapsed \(self.notch.model.state == .collapsed, privacy: .public), notch \(self.notch.model.notch.map { "\($0)" } ?? "none", privacy: .public)")
                if env["CLICKBAIT_TEST_NOTCH_HUD"] != nil {
                    Log.app.notice("Notch test: HUD \(self.notch.debugHUD(), privacy: .public)")
                    return
                }
                let hover = await self.notch.debugHover()
                Log.app.notice("Notch test: hover \(hover, privacy: .public)")
                if let folder = env["CLICKBAIT_TEST_NOTCH_RENDER"] { self.notch.debugRender(to: folder) }
                Log.app.notice("Notch test: \(self.notch.debugOpen(), privacy: .public)")
                try? await Task.sleep(for: .seconds(0.7))
                Log.app.notice("Notch test: open frame \(self.notch.debugFrame, privacy: .public)")
                self.notch.debugClose()
                try? await Task.sleep(for: .seconds(1))
                Log.app.notice("Notch test: closed → \(String(describing: self.notch.model.state), privacy: .public), frame \(self.notch.debugFrame, privacy: .public)")
            }
        }
        #endif
        overlay.onDismiss = { [weak self] in self?.coordinator.answerDismissed() }
        // Esc in other apps: taken only while ClickBait is busy, so it never reaches
        // both. Esc typed in ClickBait's own chat comes through overlay.onEscape below.
        // Esc is ClickBait's only while it is (or looks) busy, and then it never reaches the
        // app in front (it can't close a dialog or a window, or leave full screen). It stops
        // ClickBait and puts the companion back to idle blue; nothing else. Background jobs
        // carry on. Idle, Esc passes through untouched.
        escape.isBusy = { [weak self] in
            guard let self else { return false }
            return coordinator.ownsEscape || overlay.looksBusy || confirm.isShowing || readyPillShown
                || coordinator.isCardRecording
        }
        escape.onEscape = { [weak self] in _ = self?.overlay.onEscape?() }
        escape.onEscapeSeen = { [weak self] in self?.notch.escapePressed() }
        escape.onTypeToAsk = { [weak self] in self?.coordinator.startTypedChat() }
        coordinator.onChatOpenForTyping = { [weak self] in
            guard let self else { return }
            overlay.endGuide()
            chat.openForTyping(logoAt: invokedPoint ?? overlay.companionTriangleCenter)
        }
        coordinator.onChatFocus = { [weak self] in
            // Focus first: it re-homes the chat to the app in front and shows it there.
            self?.chat.focus()
            self?.chat.untuck()
        }
        // The chat stays up across apps until it's closed with ✕ or Esc (user's ask,
        // 2026-10-25): it used to hide while another app was in front. It goes along with the
        // app in front (as for a walkthrough), so a follow-up is about what's in front now.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Each app's menus are learnt as it comes to the front, for when it later won't share them.
            if app.processIdentifier != ProcessInfo.processInfo.processIdentifier { MenuMemory.learn(pid: app.processIdentifier) }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.chat.adopt(app)
            }
        }
        // Two pills: "answer's ready in Safari" rides with the companion; below it, where
        // it appeared, [let's see!] [later.] stays put. Both fade if ignored.
        chat.onReadyWhileAway = { [weak self] appName in
            guard let self else { return }
            overlay.showReadyNote("answer's ready in \(appName)", for: .seconds(10))
            guard !confirm.isShowing else { return }  // never over a question being asked
            let below = overlay.companionTopLeft
            readyPillShown = true
            confirm.show("", at: CGPoint(x: below.x, y: below.y - 30), confirm: "let's see!", cancel: "later.",
                         hint: nil, tone: .idle, waitTime: .seconds(10)) { [weak self] seeIt in
                guard let self else { return }
                readyPillShown = false
                if seeIt {
                    overlay.clearShortAnswer()  // both pills go
                    chat.homeApp?.activate()  // the chat is there, where it was
                }
            }
        }
        // Went back on their own: the offer has done its job.
        chat.onBackHome = { [weak self] in
            guard let self else { return }
            overlay.clearShortAnswer()  // "answer's ready in …" has done its job too
            guard readyPillShown else { return }
            readyPillShown = false
            confirm.hide()
        }
        coordinator.onInvoked = { [weak self] in
            guard let self else { return }
            let point = overlay.companionTriangleCenter
            invokedPoint = point
            chat.invoked(at: point)
        }
        escape.start()

        // Esc, in layers: stop what's happening; else stop pointing; else close the chat.
        overlay.onEscape = { [weak self] in
            guard let self else { return false }
            if coordinator.isCardRecording {  // Esc stops a voice recording (dropped, not asked)
                coordinator.dropCardRecording(reason: "Esc")
                return true
            }
            if readyPillShown {  // Esc on "let's see! / later." means later.
                readyPillShown = false
                confirm.hide()
                return true
            }
            var stopped = coordinator.stopActivity()
            // A card still up (stopActivity answers its own): Esc is "no".
            if confirm.isShowing { confirm.cancel(); stopped = true }
            if stopped || overlay.looksBusy {
                overlay.resetToIdle()
                return true
            }
            guard chat.isOpen else { return false }
            closeChat()
            return true
        }
        chat.companionPoint = { [weak self] in self?.overlay.companionTriangleCenter ?? NSEvent.mouseLocation }
        chat.model.onSend = { [weak self] text in
            guard let self else { return }
            // Out of the way the moment Enter is pressed, before thinking starts (it used to
            // wait ~1–2 s, until the message had been sorted).
            chat.tuck()
            coordinator.sendTyped(text)
            // Refused without a word (busy, nothing to send to): back at once.
            if !coordinator.isBusy, coordinator.state != .thinking { chat.untuck() }
        }
        chat.model.onClose = { [weak self] in self?.closeChat() }
        // C5: keep a line (Remember) or the whole chat (Save) — only on the user's click.
        // C5: keep a line (Remember) or the whole chat (Save), in either chat.
        wireKeep(chat.model)
        wireKeep(notchChat.model)
        coordinator.onChatOpen = { [weak self] firstMessage in
            guard let self else { return }
            overlay.endGuide()
            // Opens tucked, where the hotkey was pressed; grows out when the answer starts.
            chat.open(logoAt: invokedPoint ?? overlay.companionTriangleCenter, tucked: true)
            chat.model.addUser(firstMessage)
            chat.model.isBusy = true
        }
        coordinator.onChatUserMessage = { [weak self] message in
            self?.overlay.endGuide()
            self?.chat.model.addUser(message)
            self?.chat.model.isBusy = true
            self?.chat.tuck()  // out of the way while the answer comes; the companion pulses
        }
        confirm.onAnswer = { [weak self] yes in self?.coordinator.answerConfirmation(yes) }
        coordinator.onConfirmRequest = { [weak self] question in
            guard let self else { return }
            SoundCues.play(.needsYou, enabled: settings.soundCues)
            readyPillShown = false  // a real question replaces the offer
            coordinator.answerOffer(false)
            confirm.show(question, at: overlay.companionTopLeft)
        }
        coordinator.onConfirmEnd = { [weak self] in self?.confirm.hide() }
        // Before a walkthrough: [show me!] / [show me in Safari!] and ✕, lavender, staying
        // put. ✕, Esc or 8 s without a click: the steps are written in the chat instead.
        coordinator.onTutorialOffer = { [weak self] label in
            guard let self else { return }
            readyPillShown = false
            confirm.show("", at: overlay.companionTopLeft, confirm: label, cancel: "✕", hint: nil,
                         tone: .tutorial, waitTime: .seconds(8)) { [weak self] yes in
                self?.coordinator.answerOffer(yes)
            }
        }
        coordinator.onStepsWritten = { [weak self] text in
            guard let self, chat.isOpen else { return }
            chat.model.setAssistant(text)
            chat.model.isBusy = false
            chat.untuck()
        }
        coordinator.onReminderDayRequest = { [weak self] question, options, hint in
            guard let self else { return }
            readyPillShown = false
            coordinator.answerOffer(false)
            confirm.showChoice(question, options: options, at: overlay.companionTopLeft, hint: hint,
                               datePicker: true) { [weak self] answer in
                switch answer {
                case .option(let index): self?.coordinator.answerReminderChoice(index)
                case .date(let date): self?.coordinator.answerReminderDate(date)
                case .timedOut: self?.coordinator.answerReminderChoice(nil)
                }
            }
        }
        coordinator.onStopped = { [weak self] in
            guard let self, chat.model.isBusy else { return }
            // Stopped (Esc): the chat waits no longer, even parked out of sight (left busy, it
            // ignored the next question: test drive, 2026-10-24).
            guard chat.isOpen else { chat.model.isBusy = false; return }
            chat.model.setAssistant(chat.model.messages.last?.role == .assistant ? (chat.model.messages.last?.text ?? "") + " …(stopped)" : "Stopped.")
            chat.model.isBusy = false
            chat.untuck()
        }
        // Replies to typed orders, notes and questions ("Added to Reminders…", a "Do it?")
        // are said by a pill or card: kept in the conversation, the chat stays aside.
        coordinator.onChatReply = { [weak self] text in
            guard let self else { return }
            chat.model.setAssistant(text)
            chat.model.isBusy = false
            chat.park()
            // Not over a green result already saying it, nor next to a card asking it, nor
            // when the notch shows the conversation.
            if !overlay.isShowingWords, !confirm.isShowing, !chat.hostedInNotch { overlay.showShortAnswer(text) }
        }
        coordinator.onChatSource = { [weak self] credit in
            guard let self, chat.isOpen,
                  let last = chat.model.messages.last(where: { $0.role == .assistant }),
                  !last.text.contains(credit) else { return }
            chat.model.replaceLastAssistant(last.text + "\n\n" + credit)
        }
        coordinator.onChatError = { [weak self] message in
            guard let self else { return }
            chat.model.addError(message)
            chat.model.isBusy = false
            chat.park()
            overlay.show(.error(message))
        }
        coordinator.onChatClose = { [weak self] in
            self?.overlay.endGuide()
            self?.chat.close()
            self?.chat.hostedInNotch = false
        }
        coordinator.onStateChange = { [weak self, weak statusBar] state in
            statusBar?.update(for: state)
            // A tap's explanation, still undoable by a second tap: not shown yet.
            if state == .thinking, self?.coordinator.isExplainProvisional == true { return }
            // Red snip thinking lasts until the tour (the coordinator ends it); a problem or a
            // new question ends it too.
            switch state {
            case .error, .listening: self?.overlay.setSnipAnswering(false)
            default: break
            }
            self?.overlay.show(state)
            // Never left tucked away: once nothing is in progress (or it failed), it's back.
            if let self, chat.isTucked, !chat.isParked {
                switch state {
                case .error: chat.park()  // the error is a pill
                case .idle where !coordinator.isBusy: chat.untuck()
                default: break
                }
            }
        }
        coordinator.onTranscript = { [weak self, weak statusBar] text in
            statusBar?.showHeard(text)
            self?.overlay.show(.thinking, heard: text)
        }
        coordinator.tutorial = tutorial
        overlay.onClick = { [weak self] point in self?.tutorial.noteClick(point) }
        tutorial.speak = { [weak self] text in self?.coordinator.speaker.speak(text, force: true) }
        tutorial.onChecklist = { [weak self] text in
            guard let self, chat.isOpen else { return }
            chat.model.replaceLastAssistant(text)
            chat.model.isBusy = false
            chat.untuck()  // a tutorial's checklist is the answer: show it now
        }
        coordinator.onSetupFinished = { [weak self] in self?.overlay.clearWorking() }
        coordinator.onTutorialPlanning = { [weak self] planning in self?.overlay.tutorialPlanning(planning) }
        tutorial.onFinished = { [weak self] message in
            // Finished or stopped, the walkthrough no longer holds its chat: what's typed next is
            // asked (left busy, it was ignored: test drive, 2026-10-24).
            self?.chat.model.isBusy = false
            guard let self, let message else { return }
            // A tutorial that opened another app offers the way back (ignored = stay).
            if message == TutorialController.finishedMessage, let home = coordinator.tutorialReturnApp, !home.isTerminated,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != home.processIdentifier {
                confirm.show("done! back to \(home.localizedName ?? "where you were")?", at: overlay.companionTopLeft,
                             confirm: "Back", cancel: "Stay", hint: nil, tone: .tutorial) { [weak self] back in
                    guard back, let self else { return }
                    let place = coordinator.tutorialReturnPlace
                    Task { @MainActor in
                        await self.returnTo(home, title: place?.title, frame: place?.frame, tab: await place?.tab?.value)
                    }
                }
            }
            if chat.isOpen, let last = chat.model.messages.last(where: { $0.role == .assistant }) {
                chat.model.replaceLastAssistant(last.text + "\n\n" + message)
            } else if message != TutorialController.finishedMessage {
                overlay.show(.error(message))
            }
        }
        coordinator.onTour = { [weak self] parts in self?.overlay.tour(parts) }
        coordinator.onPointersRefined = { [weak self] pointers in self?.overlay.retarget(pointers) }
        coordinator.onInstantPointer = { [weak self] pointers in self?.overlay.guide(to: pointers) }
        overlay.levelSource = { [weak coordinator] in coordinator?.microphoneLevel ?? 0 }
        coordinator.onSnipMarking = { [weak self] marking in self?.overlay.setSnipping(marking) }
        coordinator.onSnipAnswering = { [weak self] on in self?.overlay.setSnipAnswering(on) }
        coordinator.onExplaining = { [weak self] selected in self?.overlay.showExplaining(selected) }
        coordinator.onPartialAnswer = { [weak self] partial in
            guard let self else { return }
            chat.model.setAssistant(partial)
            // Back once the answer is more than a pill can say (a full sentence past the pill
            // length, or a second sentence): the rest streams in view. Short replies and
            // pointing never bring it back.
            if chat.isTucked {
                var splitter = SentenceSplitter()
                let sentences = splitter.feed(partial).count
                if sentences >= 2 || (sentences >= 1 && partial.count > PillText.maxLength) { chat.untuck() }
            }
        }
        coordinator.onActionStarted = { [weak self] message in self?.overlay.showWorking(message) }
        coordinator.onActionDone = { [weak self] message in self?.overlay.showDone(message) }
        coordinator.onSearchResults = { [weak self] items in self?.chat.model.setResults(items) }
        NotificationCenter.default.addObserver(forName: .clickBaitForgetResult, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? String else { return }
            MainActor.assumeIsolated {
                self?.chat.model.removeResult(id)
                self?.coordinator.lastSearchResults.removeAll { $0.id == id }
            }
        }
        NotificationCenter.default.addObserver(forName: .clickBaitListenAgain, object: nil, queue: .main) { [weak self] note in
            guard let text = note.object as? String else { return }
            MainActor.assumeIsolated {
                self?.coordinator.speaker.stop()
                self?.coordinator.speaker.speak(text, force: true)
            }
        }
        coordinator.onAnswer = { [weak self, weak statusBar] response, pointers in
            statusBar?.showAnswer(response.speech, pointers: pointers.map { "\($0.label) at \($0.quartz)" })
            guard let self else { return }
            // Pointing, or a few friendly words: the companion says it; the chat isn't needed.
            let short = PillText.fits(response.speech, code: response.code)
            let pillSays = short || !pointers.isEmpty
            if chat.isOpen {
                // Final text, with any code as a block, over the streamed one: while still busy
                // (set not busy first, it was added again below the streamed copy: the answer
                // showed twice, user's report 2026-10-25).
                chat.model.setAssistant(response.displayText)
                if !pillSays {
                    chat.untuck()
                } else if chat.isTucked {
                    chat.park()  // kept in the conversation; a double tap brings it back
                }
            }
            // The answer is in: the chat waits no longer, open or parked out of sight (a pointing
            // answer parks it first, and left busy it ignored the next question: test drive).
            chat.model.isBusy = false
            // Already pointing (instantly, before the model): don't start over. The reply's
            // own few words label the pointer when they fit ("Share's up here!").
            if !pointers.isEmpty {
                if !coordinator.pointedInstantly { overlay.guide(to: pointers, label: short ? response.speech : nil) }
            } else if short, !(chat.isOpen && !chat.isTucked) {
                overlay.showShortAnswer(response.speech)
            }
        }
        hotkey.start()
        TextReader.warmUp()
        // Models load now and stay loaded while ClickBait runs (no reload after a break).
        let provider = settings.makeProvider()
        Task.detached(priority: .utility) { await provider.warmUp() }
        speech.loadIfInstalled()
        if let voice = KokoroVoice.name(in: settings.voiceIdentifier), KokoroVoice.isInstalled {
            Task.detached(priority: .utility) { await KokoroEngine.shared.warmUp(voice: voice) }
        }

        logPermissions()
        if onboardingWindow.shouldShowAtLaunch {
            onboardingWindow.show()
        }
    }

    /// Two copies would mean two menu bar icons and two hotkey listeners. The newest
    /// launch wins, so Xcode's ⌘R replaces an already-running build.
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != currentPID {
            app.terminate()
        }
    }

    private func logPermissions() {
        for kind in PermissionKind.allCases {
            Log.app.notice("Permission \(kind.title, privacy: .public): \(String(describing: self.permissions.status(of: kind)), privacy: .public)")
        }
    }

    /// The first time a done card opens: ask for its "suggested next:" pills.
    private func suggestNext(for id: UUID) {
        guard let entry = backgroundJobs.entries.first(where: { $0.id == id }), entry.suggestions == nil,
              entry.walkthrough == nil, entry.job.kind != .files,  // their one next step is "show me!"
              case .done = entry.job.status, !askingSuggestions.contains(id) else { return }
        askingSuggestions.insert(id)
        let question = entry.job.question, answer = entry.job.answer
        let isSnip = entry.job.kind == .snip
        Task { @MainActor [weak self] in
            guard let self else { return }
            let suggestions = await coordinator.suggestNext(question: question, answer: answer)
            askingSuggestions.remove(id)
            // A snip's card always offers the full explanation first (user's ask, 2026-10-25).
            let more = isSnip ? [PeelRule.tellMorePrompt] : []
            // Slow or unusable: none this time; the next opening asks again (a snip still gets "tell me more").
            if let suggestions { backgroundJobs.setSuggestions(more + suggestions.prefix(isSnip ? 1 : 2), for: id) }
            else if isSnip { backgroundJobs.setSuggestions(more, for: id) }
        }
    }

    /// A job that has just finished shows its summary once by the companion (the result
    /// pill), waiting while ClickBait is busy (listening, thinking, speaking), pointing or
    /// touring, or walking through something; given up after 2 minutes.
    private func announceFinished(_ entries: [BackgroundJobs.Entry]) {
        for entry in entries where !announcedJobs.contains(entry.id) {
            guard case .done(let summary) = entry.job.status, !summary.hasPrefix("your chat about") else { continue }
            announcedJobs.insert(entry.id)
            let id = entry.id
            let tone = entry.job.kind.tone
            // Not the answer: a short note that it's done, fitting the task (`DonePill`); the
            // card has the answer. The morning card keeps its greeting.
            let headline: String
            if entry.job.question == "Good morning" {
                headline = entry.job.answer.isEmpty ? summary : JobSummary.headline(from: entry.job.answer)
            } else {
                headline = DonePill.line(for: DonePill.task(kind: entry.job.kind, question: entry.job.question, answer: entry.job.answer),
                                         after: lastDoneLine)
                lastDoneLine = headline
            }
            showWhenQuiet(headline, tone: tone, for: .seconds(120), while: { [weak self] in
                self?.backgroundJobs.entries.contains(where: { $0.id == id }) ?? false  // gone, or opened there
            })
        }
        announcedJobs.formIntersection(entries.map(\.id))
    }

    /// Shows a result pill once nothing else is being said, pointed at or walked through;
    /// given up after `limit`, or as soon as `stillWanted` says no.
    private func showWhenQuiet(_ text: String, tone: CompanionTone, for limit: Duration, while stillWanted: @escaping () -> Bool) {
        Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + limit
            while let self, ContinuousClock.now < deadline {
                guard stillWanted() else { return }
                if !coordinator.isBusy, !overlay.isGuiding, !overlay.isTutoring, !overlay.isShowingWords {
                    overlay.showJobResult(text, tone: tone)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// The gallery's Watch page, and the nearby Macs and cards wired up beside it.
    private func wireGallery() {
        ConfirmController.notchFrames = { [weak self] in self?.notch.visibleFrames ?? [] }
        NearbyMacs.shared.ask = { [weak self] question, answer in
            guard let self else { return answer(false) }
            confirm.show(question, at: overlay.companionTopLeft, confirm: "accept", cancel: "no",
                         hint: nil, tone: .action, waitTime: .seconds(60)) { answer($0) }
        }
        NearbyMacs.shared.onReceived = { [weak self] from, files in
            guard let self else { return }
            SoundCues.play(.done, enabled: settings.soundCues)
            overlay.showJobResult("got \(files.count == 1 ? "1 file" : "\(files.count) files") from \(from) ✓ in Downloads", tone: .idle, force: true)
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
        NearbyMacs.shared.start()
        GalleryHooks.watch = { [weak self] rule in
            guard let self else { return }
            notch.makeRoom()
            WatchAreaPicker.pick { [weak self] area in
                guard let self, let area else { return }
                ScreenWatcher.shared.start(area: area, rule: rule, blocklist: settings.blocklist)
                overlay.showJobResult("watching \(rule.summary)", tone: .idle, force: true)
            }
        }
        ScreenWatcher.shared.onDone = { [weak self] text in
            guard let self else { return }
            SoundCues.play(.done, enabled: settings.soundCues)
            overlay.showJobResult(text, tone: .idle, force: true)
        }
    }

    /// Claude Code and Codex notices (user's ask, 2026-11-02). Asked once, the first launch after
    /// this arrived, whether to add the hooks; the switch in Settings adds or removes them after.
    private func startAgentNotices() {
        if !settings.agentNoticesAsked {
            settings.agentNoticesAsked = true
            let alert = NSAlert()
            alert.messageText = "Tell you when Claude Code or Codex needs you?"
            alert.informativeText = "ClickBait shows a pill by the cursor when Claude Code needs you or finishes, and when Codex finishes, unless you're already looking at it. For Claude Code it adds two small hooks to its settings (~/.claude/settings.json), beside your own; switching this off in Settings takes them out. Nothing is sent anywhere."
            alert.addButton(withTitle: "Turn on")
            alert.addButton(withTitle: "Not now")
            NSApp.activate()
            settings.agentNotices = alert.runModal() == .alertFirstButtonReturn
        }
        startObservingAgentSetting()
    }

    /// Applies the switch now and again whenever it changes.
    private func startObservingAgentSetting() {
        applyAgentNotices()
        withObservationTracking { _ = settings.agentNotices } onChange: { [weak self] in
            Task { @MainActor in self?.startObservingAgentSetting() }
        }
    }

    private func applyAgentNotices() {
        if settings.agentNotices {
            if !AgentHookInstaller.isInstalled { AgentHookInstaller.install() }
            agents.start()
        } else {
            agents.stop()
            AgentHookInstaller.remove()
        }
    }

    /// By the cursor (user's rule: notices at the companion). Skipped while the app it runs in is
    /// in front: the person is watching it. "Needs you" is a card whose [go there] brings that
    /// app forward; "finished" is a pill.
    /// Terminal's tab on `tty` selected, its window in front, Terminal active. `tty` is checked
    /// well-formed (`AgentNotice`), so it's safe inside the script.
    private static func bringTerminalTab(_ tty: String) {
        let script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "/dev/\(tty)" then
                            set selected of t to true
                            set index of w to 1
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { Log.app.error("Go there: \(error, privacy: .public)") }
    }

    private func showAgentNotice(_ notice: AgentNotice) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let app = notice.app, app == front { return }
        if notice.app == nil, notice.tool == .codex, front == "com.openai.codex" { return }
        Log.app.notice("Agent notice: \(notice.toolName, privacy: .public) \(String(describing: notice.kind), privacy: .private)")
        let tone: CompanionTone = notice.tool == .claude ? .claude : .codex
        switch notice.kind {
        case .finished:
            SoundCues.play(.done, enabled: settings.soundCues)
            overlay.showJobResult(notice.line, tone: tone, force: !coordinator.isBusy)
        case .needsYou(let detail):
            SoundCues.play(.needsYou, enabled: settings.soundCues)
            guard !coordinator.isBusy, coordinator.pendingAction == nil, let app = notice.app,
                  let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first else {
                overlay.showJobResult(notice.line, tone: tone, force: true)
                return
            }
            confirm.show(notice.line, at: overlay.companionTopLeft, confirm: "go there", cancel: "later",
                         hint: detail, tone: tone, waitTime: .seconds(15)) { yes in
                guard yes else { return }
                // Terminal: that very tab, on whichever display its window is (user's ask, 2026-11-02).
                if app == "com.apple.Terminal", let tty = notice.tty {
                    Self.bringTerminalTab(tty)
                } else {
                    running.activate()
                }
            }
        }
    }

    /// "peek at it?" by the companion for an archive dropped on the shelf: an offer in the idle
    /// look, answered by click, "peek" or "yes"; never twice for one file. Taken, it turns green
    /// while it looks (the working pill), then the contents with an extract button.
    private func offerPeek(_ archive: URL) {
        guard !offeredPeeks.contains(archive), coordinator.offerPeek(archive) else { return }
        offeredPeeks.insert(archive)
        confirm.show("peek at it?", at: overlay.companionTopLeft, confirm: "peek", cancel: "not now",
                     hint: "or say “peek”", tone: .idle, waitTime: .seconds(8)) { [weak self] yes in
            Task { @MainActor in await self?.coordinator.resolvePending(yes) }
        }
    }

    /// A taken peek: the contents in a green card with an extract button (straight to the
    /// dock, being the answer it asked for).
    /// `then`: once the chat is open in the home context (a clicked suggestion is sent then).
    private func goThere(_ id: UUID, then: (() -> Void)? = nil) {
        guard !coordinator.isBusy,
              let entry = backgroundJobs.entries.first(where: { $0.id == id }),
              case .done = entry.job.status else { return }
        let job = entry.job
        var messages = entry.chatMessages
        if messages.isEmpty {
            messages.append(ChatModel.Message(role: .user, text: job.question))
            if !job.answer.isEmpty { messages.append(ChatModel.Message(role: .assistant, text: job.answer)) }
        }

        var homeApp = job.homePID.flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
        if homeApp?.isTerminated == true { homeApp = nil }
        if homeApp == nil, let bundleID = job.homeBundleID {
            homeApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }

        // A walkthrough: back there and start it, no chat. An opened chat took focus from
        // that app, so the walkthrough thought the user had left and kept switching back.
        if entry.walkthrough != nil {
            backgroundJobs.remove(id)
            // Lavender from here to the first point ("taking you to Safari…"), never green.
            overlay.setTutoring(true)
            overlay.showWorking("taking you to \(homeApp?.localizedName ?? "where you asked")…")
            Task { @MainActor in
                await returnHome(job, homeApp: homeApp)
                then?()
            }
            return
        }

        if chat.isOpen {
            let oldHome = chat.homeApp
            let oldBundleID = chat.homeBundleID
            let oldPID = chat.homeProcessID
            let oldMessages = chat.stash()
            let detached = coordinator.detachChatForCapsule()
            let oldConversation = detached?.conversation ?? Conversation()
            let firstQuestion = oldMessages.first(where: { $0.role == .user })?.text ?? "your chat"
            let answer = oldMessages.last(where: { $0.role == .assistant })?.text ?? ""
            var displaced = BackgroundJob(question: firstQuestion, kind: .answer,
                                          homeBundleID: oldBundleID ?? oldHome?.bundleIdentifier,
                                          homePID: oldPID ?? oldHome.map { Int32($0.processIdentifier) },
                                          conversation: oldConversation)
            displaced.complete(summary: "your chat about \(firstQuestion)", answer: answer, conversation: oldConversation)
            backgroundJobs.remove(id)
            if backgroundJobs.add(displaced, task: nil) {
                backgroundJobs.setChatMessages(oldMessages, for: displaced.id)
                backgroundJobs.setSnipMemory(detached?.snipMemory, for: displaced.id)
            }
        } else {
            backgroundJobs.remove(id)
        }

        coordinator.restoreBackgroundConversation(job.conversation, snipMemory: entry.snipMemory)
        let snipArea = entry.snipMemory?.view?.markedOnScreen
        Task { @MainActor in
            // Back to where it was asked first; the chat opens there once the move is done
            // (it used to open at once, left behind on the desktop the user came from).
            await returnHome(job, homeApp: homeApp)
            let spot = chatSpot(snipArea: snipArea, homeApp: homeApp)
            chat.restore(messages, logoAt: spot, homeApp: homeApp)
            Log.app.notice("Go there: chat opened \(snipArea != nil ? "by the snipped area" : "in its window", privacy: .public)")
            then?()
        }
    }

    /// Brings back the tab, window and desktop a job was asked in, and returns once the move
    /// is over. In Chrome or Safari the browser selects the exact tab, brings its window front
    /// and switches to its desktop (accessibility can't see windows on other desktops).
    /// Otherwise, or if the tab is gone: that window (un-minimised, raised), then its app.
    private func returnHome(_ job: BackgroundJob, homeApp: NSRunningApplication?) async {
        guard let homeApp else {
            Log.app.notice("Go there: its app has quit")
            return
        }
        await returnTo(homeApp, title: job.homeWindowTitle, frame: job.homeWindowFrame, tab: job.homeTab)
    }

    /// Back to an exact place: a browser's tab when known, else that app's window by title or
    /// frame, following it to its desktop. "Go there!" and a walkthrough's "Back" both use it.
    private func returnTo(_ homeApp: NSRunningApplication, title: String?, frame: Rect?, tab homeTab: BrowserTab?) async {
        let pid = homeApp.processIdentifier
        let spaceChange = SpaceChangeWatch()
        var found = false
        if let tab = homeTab {
            switch tab.browser {
            case .chrome: found = await Task.detached(priority: .userInitiated) { ChromeTabs.select(tab, pid: pid) }.value
            case .safari: found = (try? await AppleScriptRunner.run(tab.safariReturnScript, app: tab.browser.name)) == "true"
            }
            if found { Log.app.notice("Go there: its tab, by \(tab.browser.name, privacy: .public)") }
        }
        var returned = AXInspector.HomeReturn.byTab
        if !found {
            returned = AXInspector.raiseHomeWindow(pid: pid, title: title, frame: frame)
            AXInspector.bringToFront(pid: pid)
            homeApp.activate()
            Log.app.notice("Go there: \(homeTab != nil ? "the tab is gone; " : "", privacy: .public)\(returned.rawValue, privacy: .public)")
        }
        // In front, and the desktop switch (if any) over: the chat must open on the new one.
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let switched = await spaceChange.wait(upTo: .milliseconds(700))
        if switched { try? await Task.sleep(for: .milliseconds(150)) }  // the slide settles
        // Its window was on another desktop (accessibility sees only this one's): now that the
        // app's desktop is showing, look again and raise that exact window.
        if returned == .none || returned == .byFrame {
            let again = AXInspector.raiseHomeWindow(pid: pid, title: title, frame: frame)
            if again != .none { Log.app.notice("Go there: on its desktop, \(again.rawValue, privacy: .public)") }
        }
        Log.app.notice("""
            Go there: app in front \(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, privacy: .public), \
            desktop switched \(switched, privacy: .public)
            """)
    }

    /// Where the chat comes back (AppKit): by the top-right of what was snipped, else inside
    /// the home window's top right (its focused window, now on this desktop), else at the
    /// companion.
    private func chatSpot(snipArea: Rect?, homeApp: NSRunningApplication?) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if let area = snipArea {
            return CGPoint(x: area.maxX, y: primaryHeight - area.minY)
        }
        if let pid = homeApp?.processIdentifier, let frame = AXInspector.focusedWindowFrameOnScreen(pid: pid) {
            return CGPoint(x: frame.maxX - 40, y: primaryHeight - frame.minY - 90)
        }
        return overlay.companionTriangleCenter
    }

    /// ✕ or Escape on the chat bubble: close it and forget the conversation.
    private func closeChat() {
        coordinator.closeChat()
        overlay.endGuide()
        chat.close()
        // Closed in the notch: back to its main panel, the notch staying open.
        if chat.hostedInNotch {
            chat.hostedInNotch = false
            notch.model.tab = .home
        }
    }

    /// "Saved" / "Remembered" in the chat's header for a moment. (Was inside `#if DEBUG`, so
    /// Release builds didn't compile.)
    /// Remember (a line of the last answer) and Save (the chat as a file), only on the user's click.
    private func wireKeep(_ model: ChatModel) {
    model.onRemember = { [weak self, weak model] in
        guard let self, let model, let answer = model.messages.last(where: { $0.role == .assistant })?.text else { return }
        let prose = MessageFormat.segments(answer).compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
        let first = prose.split(separator: ".", maxSplits: 1).first.map(String.init) ?? prose
        guard let line = RememberPrompt.confirm(String(first.prefix(160))) else { return }
        let reply = MemoryStore.shared.reply(to: .remember(line))
        if reply.ok { Self.flashKept("Remembered", in: model) } else { RememberPrompt.tell(reply.message) }
    }
    model.onSaveAnswer = { [weak model] in
        guard let model else { return }
        let turns: [(role: SavedAnswer.Role, text: String)] = model.messages.compactMap { message in
            switch message.role {
            case .user: (.user, message.text)
            case .assistant: (.assistant, message.text)
            case .error: nil
            }
        }
        guard let file = AnswerArchive.save(turns) else { RememberPrompt.tell("Couldn't save this answer."); return }
        Self.flashKept("Saved", in: model)
        AnswerArchive.reveal(file)
    }
    }

    private static func flashKept(_ note: String, in model: ChatModel) {
        model.keptNote = note
        Task { @MainActor [weak model] in
            try? await Task.sleep(for: .seconds(1.6))
            model?.keptNote = nil
        }
    }

    #if DEBUG
    /// The background dock with no model (`CLICKBAIT_BENCH_DOCK=1`): three tiles (two
    /// working, one done) for 8 s, a running card streaming for 6 s, then three peels into the top slot, each sliding the
    /// others down. Logged "Bench: …" per phase for the main-thread sampler.

    #if DEBUG
    /// `CLICKBAIT_TEST_GUIDANCE` (=<folder> also renders it): a labelled highlight and an armed,
    /// pulsing arrow at one region; checks the arrow is primary and on top, the labels apart, a
    /// click outside does nothing, a click inside advances (and dismisses) only the armed guide,
    /// a resize moves the box, and dismissing the rest clears the overlay.
    private func runGuidanceTestIfRequested() {
        guard let value = ProcessInfo.processInfo.environment["CLICKBAIT_TEST_GUIDANCE"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let screen = NSScreen.screens.first?.frame ?? .zero
            let region = CGRect(x: screen.midX - 150, y: screen.midY - 50, width: 300, height: 100)
            var advanced = 0
            let box = guidance.show(GuideRequest(kind: .highlight, target: .bounds(region), label: "Recent files", priority: 1))
            let arrow = guidance.show(GuideRequest(kind: .arrow, target: .point(CGPoint(x: region.midX, y: region.midY)),
                                                   label: "Click here", priority: 2, armed: true, pulse: true,
                                                   onArmedClick: { advanced += 1 }))
            let items = guidance.debugItems
            let primary = items.last.map { "\($0.kind)" } ?? "none"
            let labels = items.compactMap(\.labelFrame)
            let apart = labels.count == 2 && !labels[0].intersects(labels[1])
            if value != "1" {
                let renderer = ImageRenderer(content: guidance.debugOverlay.frame(width: screen.width, height: screen.height)
                    .background(Color(white: 0.92)))
                renderer.scale = 1
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: value).appendingPathComponent("guidance.png"))
                }
            }
            guidance.clicked(at: CGPoint(x: 5, y: 5))
            let outside = advanced
            guidance.clicked(at: CGPoint(x: region.midX + 4, y: region.midY + 3))
            let inside = advanced, left = guidance.debugItems.count
            box.update(target: .bounds(region.insetBy(dx: -40, dy: -20)))
            let grown = guidance.debugItems.first?.box?.width ?? 0
            box.dismiss()
            arrow.dismiss()  // already gone: a no-op
            Log.app.notice("Guidance test: primary \(primary, privacy: .public), labels apart \(apart), outside click advanced \(outside), inside click advanced \(inside), guides left \(left), resized box \(grown) (was \(region.width + 12)), cleared \(self.guidance.debugItems.isEmpty)")
        }
    }
    #endif

    /// `CLICKBAIT_TEST_MENUS=1`: logs what Accessibility returns for each running app's menu
    /// bar (raw error codes), to tell a ClickBait bug from macOS not exposing menus.
    private func runMenuTestIfRequested() {
        guard ProcessInfo.processInfo.environment["CLICKBAIT_TEST_MENUS"] != nil else { return }
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                var bar: CFTypeRef?
                let barError = AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &bar)
                var names: [String] = []
                if barError == .success, let bar {
                    var children: CFTypeRef?
                    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
                    for child in (children as? [AXUIElement] ?? []).prefix(8) {
                        var title: CFTypeRef?
                        AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &title)
                        names.append(title as? String ?? "?")
                    }
                }
                let outline = AXInspector.menuOutline(frontmostPID: app.processIdentifier).count
                Log.app.notice("Menu test: \(app.localizedName ?? "?", privacy: .public) bar \(barError.rawValue, privacy: .public) items \(names.joined(separator: ","), privacy: .public) outline \(outline, privacy: .public) trusted \(AXIsProcessTrusted(), privacy: .public)")
            }
        }
    }

    /// `CLICKBAIT_TEST_GOTHERE=<Chrome pid>`: a done job whose home is a tab that isn't
    /// showing, in Chrome's back-most window with more than one tab; "go there!" on it; then
    /// checks the tab is focused and showing, and the chat opened on this desktop inside it.
    private func runGoThereTestIfRequested() {
        guard let value = ProcessInfo.processInfo.environment["CLICKBAIT_TEST_GOTHERE"], let pid = pid_t(value) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let target: BrowserTab? = await Task.detached { () -> BrowserTab? in
                guard let app = SBApplication(processIdentifier: pid), let windows = app.value(forKey: "windows") as? SBElementArray else { return nil }
                func value(_ object: SBObject, _ key: String) -> Any? {
                    let raw = object.value(forKey: key)
                    return (raw as? SBObject)?.get() ?? raw
                }
                for case let window as SBObject in windows.reversed() {
                    guard let tabs = window.value(forKey: "tabs") as? SBElementArray, tabs.count > 1,
                          let active = (value(window, "activeTabIndex") as? NSNumber)?.intValue else { continue }
                    let pick = active == 1 ? 2 : 1
                    guard let tab = tabs.object(at: pick - 1) as? SBObject,
                          let id = value(tab, "id").flatMap({ Int("\($0)") }) else { continue }
                    return BrowserTab(browser: .chrome, windowID: value(window, "id").flatMap { Int("\($0)") } ?? 0,
                                      tab: id, title: value(tab, "title") as? String ?? "", url: "")
                }
                return nil
            }.value
            guard let target else {
                Log.app.notice("GT: no window with a hidden tab")
                return
            }
            var job = BackgroundJob(question: "go there test", kind: .answer, homeBundleID: "com.google.Chrome",
                                    homePID: pid, conversation: Conversation())
            job.homeTab = target
            guard backgroundJobs.add(job, task: nil) else {
                Log.app.notice("GT: dock full")
                return
            }
            backgroundJobs.complete(job.id, answer: "Test answer.", conversation: Conversation())
            try? await Task.sleep(for: .seconds(0.5))
            goThere(job.id) {
                let focused = AXInspector.focusedWindowTitle(pid: pid)
                let window = AXInspector.focusedWindowFrameOnScreen(pid: pid)
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                let placement = self.chat.debugPlacement
                let inside = placement.flatMap { chat -> Bool? in
                    guard let window else { return nil }
                    let top = primaryHeight - chat.frame.maxY  // the chat's top, in Quartz
                    return chat.frame.midX >= window.minX && chat.frame.midX <= window.maxX && top >= window.minY && top <= window.maxY
                }
                Log.app.notice("""
                    GT: front app pid \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, privacy: .public); \
                    shows target \(HomeWindow.tabMatches(target.title, page: focused ?? ""), privacy: .public); \
                    chat on this desktop \(placement?.onThisDesktop ?? false, privacy: .public); \
                    chat inside its window \(inside.map { "\($0)" } ?? "unknown", privacy: .public)
                    """)
            }
        }
    }

    /// `CLICKBAIT_TEST_CARD_VOICE=1`: a done card's voice button records ~1.5 s, folding drops it,
    /// then voice pressed twice fast (no model: nothing is transcribed).
    private func runCardVoiceTestIfRequested() {
        guard ProcessInfo.processInfo.environment["CLICKBAIT_TEST_CARD_VOICE"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let done = BackgroundJob(question: "card voice test", kind: .answer, homeBundleID: nil, homePID: nil, conversation: Conversation())
            backgroundJobs.add(done, task: nil)
            backgroundJobs.complete(done.id, answer: "Test answer.", conversation: Conversation())
            try? await Task.sleep(for: .seconds(0.5))
            capsules.expand(done.id)
            try? await Task.sleep(for: .seconds(0.5))
            capsules.followUp(done.id, .tap(.voice))
            Log.app.notice("Test: after voice: \(self.capsules.followUpState(done.id), privacy: .public), recording \(self.coordinator.isCardRecording, privacy: .public)")
            try? await Task.sleep(for: .seconds(1.5))
            Log.app.notice("Test: 1.5 s on: \(self.capsules.followUpState(done.id), privacy: .public), recording \(self.coordinator.isCardRecording, privacy: .public)")
            capsules.followUp(done.id, .collapse)  // folding drops the recording, no model
            Log.app.notice("Test: after fold: \(self.capsules.followUpState(done.id), privacy: .public), recording \(self.coordinator.isCardRecording, privacy: .public)")
            capsules.followUp(done.id, .tap(.voice))
            capsules.followUp(done.id, .tap(.voice))  // pressed while the mic starts: gives up
            Log.app.notice("Test: rapid voice ×2: \(self.capsules.followUpState(done.id), privacy: .public), recording \(self.coordinator.isCardRecording, privacy: .public)")
        }
    }

    /// `CLICKBAIT_TEST_NOTCH_VOICE=1`: the notch Ask card's voice wiring end to end, as the
    /// card calls it (its start once read success as "isn't ready" and left the microphone on,
    /// 2026-10-24). Records ~1 s of the room each step; nothing is asked. Logs PASS or FAIL.
    private func runNotchVoiceTestIfRequested() {
        guard ProcessInfo.processInfo.environment["CLICKBAIT_TEST_NOTCH_VOICE"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))  // the speech model loads
            var failures: [String] = []
            func check(_ ok: Bool, _ what: String) {
                if !ok { failures.append(what) }
                Log.app.notice("Notch voice test: \(ok ? "ok" : "FAILED", privacy: .public) \(what, privacy: .public)")
            }
            // 1. Start: success is nil, and the microphone is on.
            let reason = notch.model.voiceStart()
            check(reason == nil && coordinator.isCardRecording, "start → recording (got \(reason ?? "nil"))")
            try? await Task.sleep(for: .seconds(1))
            // 2. Stop: a result, and the microphone is off.
            let result = await notch.model.voiceFinish()
            if case .failure(let error) = result { check(false, "stop → \(error.message)") } else { check(true, "stop → heard") }
            check(!coordinator.isCardRecording, "stop → microphone off")
            // 3. Dictation takes the microphone from a recording.
            _ = notch.model.voiceStart()
            let dictation = coordinator.startDictation()
            check(dictation == nil && !coordinator.isCardRecording, "dictation takes over (got \(dictation ?? "nil"))")
            _ = await coordinator.finishDictation(prompt: "")
            coordinator.endDictation()
            // 4. Esc stops a recording.
            _ = notch.model.voiceStart()
            _ = overlay.onEscape?()
            check(!coordinator.isCardRecording, "Esc stops the recording")
            Log.app.notice("Notch voice test: \(failures.isEmpty ? "PASS" : "FAIL: " + failures.joined(separator: "; "), privacy: .public)")
        }
    }

    /// `CLICKBAIT_ROUTE_BENCH=1`: the local model sorts every labelled question (`RoutingCases`)
    /// as the shadow router does, with no screen; logs each miss and the accuracy. Asks the model
    /// ~50 short questions (a minute or two).
    private func runRouteBenchIfRequested() {
        guard ProcessInfo.processInfo.environment["CLICKBAIT_ROUTE_BENCH"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            let provider = settings.makeProvider()
            let apps = Array(AppLocator.installed().keys)
            var right = 0
            let start = ContinuousClock.now
            for item in RoutingCases.all {
                var ask = AskRequest(question: item.question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                                     context: ScreenContext(appName: "Safari"))
                ask.routeIntent = true
                let reply = await AskCoordinator.reply(from: provider, to: ask, within: ProviderOperation.classifyRequest.timeout)
                let got = reply.flatMap { IntentRouter.parse($0, apps: apps) }?.intent
                if got == item.expected { right += 1 } else {
                    Log.app.notice("Route bench: miss \"\(item.question, privacy: .public)\": \(item.expected.rawValue, privacy: .public) → \(got?.rawValue ?? "no reply", privacy: .public)")
                }
            }
            Log.app.notice("Route bench: \(right, privacy: .public)/\(RoutingCases.all.count, privacy: .public) right in \(String(describing: ContinuousClock.now - start), privacy: .public)")
        }
    }

    private func runDockBenchmarkIfRequested() {
        guard ProcessInfo.processInfo.environment["CLICKBAIT_BENCH_DOCK"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            func job(_ kind: BackgroundJob.Kind) -> BackgroundJob {
                BackgroundJob(question: "why does this crash on launch", kind: kind, homeBundleID: nil, homePID: nil,
                              conversation: Conversation())
            }
            Log.app.notice("Bench: dock")
            let done = job(.answer)
            backgroundJobs.add(done, task: nil)
            backgroundJobs.complete(done.id, answer: "It's nil until Settings load.", conversation: Conversation())
            backgroundJobs.add(job(.answer), task: nil)
            backgroundJobs.add(job(.snip), task: nil)
            try? await Task.sleep(for: .seconds(8))
            // The running card open while its answer streams, ~12 updates a second.
            Log.app.notice("Bench: card")
            if let working = backgroundJobs.entries.first(where: { $0.job.isWorking }) {
                capsules.expand(working.id)
                let words = "The error means the optional was nil when it was force-unwrapped on line 42. ".split(separator: " ")
                for index in 0..<72 {
                    if ProcessInfo.processInfo.environment["CLICKBAIT_BENCH_DOCK"] != "still" {
                        backgroundJobs.append("", speech: words[index % words.count] + " ", to: working.id)
                    }
                    try? await Task.sleep(for: .milliseconds(83))
                }
                capsules.fold(working.id)
            }
            // The done card with its suggestions (set here, so no model is asked).
            Log.app.notice("Bench: result")
            backgroundJobs.setSuggestions(["Show me the fixed code", "Why is it nil at launch?"], for: done.id)
            capsules.expand(done.id)
            try? await Task.sleep(for: .seconds(4))
            capsules.fold(done.id)
            Log.app.notice("Bench: peel")
            for _ in 0..<3 {
                if let last = backgroundJobs.entries.last { backgroundJobs.remove(last.id) }
                let next = job(.snip)
                backgroundJobs.add(next, task: nil)
                let index = backgroundJobs.entries.firstIndex(where: { $0.id == next.id })
                overlay.peel(to: index.flatMap { capsules.slotCenter(forIndex: $0) }, tone: .capture, completion: {})
                try? await Task.sleep(for: .seconds(2))
            }
            Log.app.notice("Bench: done")
            backgroundJobs.removeAll()
        }
    }

    /// Streams a canned answer into an open chat, ~12 updates a second as real answers come,
    /// with no model (`CLICKBAIT_BENCH_CHAT=1`): for the "Companion stalled" log and samples.
    private func runChatBenchmarkIfRequested() {
        guard ProcessInfo.processInfo.environment["CLICKBAIT_BENCH_CHAT"] != nil else { return }
        let answer = String(repeating: "The list of prices is **empty**, so `len(prices)` is 0 and Python can't divide by zero. ", count: 6)
            + "\n\n```python\ntotal = sum(prices) / len(prices) if prices else 0\n```\n\nThen run it again with an empty cart."
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            Log.app.notice("Bench: chat open")
            chat.open(logoAt: overlay.companionTriangleCenter)
            chat.model.addUser("why does this crash?")
            chat.model.isBusy = true
            try? await Task.sleep(for: .seconds(1))
            Log.app.notice("Bench: chat stream")
            // The companion tours meanwhile, so a stall during streaming is logged.
            if let screen = NSScreen.main?.frame {
                overlay.tour((0..<4).map { index in
                    let x = screen.midX + 300 * cos(Double(index) * .pi / 2), y = screen.midY + 200 * sin(Double(index) * .pi / 2)
                    return ScreenPointer(label: "part \(index + 1)", appKit: Point(x: x, y: y), quartz: Point(x: x, y: screen.maxY - y))
                })
            }
            var shown = 0
            while shown < answer.count {
                shown = min(answer.count, shown + 9)
                chat.model.setAssistant(String(answer.prefix(shown)))
                try? await Task.sleep(for: .milliseconds(83))
            }
            chat.model.isBusy = false
            try? await Task.sleep(for: .seconds(1))
            Log.app.notice("Bench: chat done")
        }
    }
    #endif
}

/// Whether the active desktop changes, from when it's made: "go there!" waits for the slide
/// before opening the chat, so it opens on the new desktop.
@MainActor
private final class SpaceChangeWatch {
    private var changed = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed = true }
        }
    }

    /// True if it changed by the end of `limit`.
    func wait(upTo limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !changed, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(40)) }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        return changed
    }
}
