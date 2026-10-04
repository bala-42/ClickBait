import AppKit
import ClickBaitCore
import AudioToolbox
import Carbon.HIToolbox
import CoreAudio
import CoreWLAN
import EventKit
import ImageIO
import UniformTypeIdentifiers

enum ActionExecutionError: LocalizedError {
    case appNotFound(String)
    case appNotRunning(String)
    case audio(String)
    case script(String)
    case shortcutFailed(String, String)
    case wifi(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let name): "I couldn't find an app called “\(name)”."
        case .appNotRunning(let name): "“\(name)” isn't running."
        case .audio(let detail): "I couldn't change the sound: \(detail)."
        case .script(let detail): "macOS didn't let me do that: \(detail)"
        case .shortcutFailed(let name, let detail): "The shortcut “\(name)” didn't finish: \(detail)"
        case .wifi(let detail): "I couldn't change Wi-Fi: \(detail)"
        }
    }
}

/// Carries out validated actions. Only `ResolvedAction`s reach here — the model's
/// proposal has already been checked against `ActionCatalog` and the allowed shortcuts.
@MainActor
enum ActionExecutor {
    /// Runs the action and returns a short past-tense confirmation for the bubble.
    /// `blocklist` keeps blocked apps out of screenshots ClickBait takes for the user.
    static func run(_ action: ResolvedAction, blocklist: AppBlocklist = .defaults) async throws -> String {
        switch action {
        case .openApp(let name):
            guard let url = AppLocator.url(forAppNamed: name) else { throw ActionExecutionError.appNotFound(name) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return "Opened \(app.localizedName ?? url.deletingPathExtension().lastPathComponent)"

        case .quitApp(let name):
            let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            let names = running.compactMap(\.localizedName)
            guard let match = ActionCatalog.bestMatch(for: name, in: names, threshold: 0.75),
                  let app = running.first(where: { $0.localizedName == match })
            else { throw ActionExecutionError.appNotRunning(name) }
            app.terminate()
            return "Quit \(match)"

        case .setVolume(let percent):
            try SystemAudio.setVolume(Float(percent) / 100)
            if percent > 0 { try? SystemAudio.setMuted(false) }
            return "Volume set to \(percent)%"

        case .setMuted(let muted):
            try SystemAudio.setMuted(muted)
            return muted ? "Muted" : "Unmuted"

        case .setDarkMode(let dark):
            try await AppleScriptRunner.run(
                "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"
            )
            return dark ? "Dark Mode on" : "Light Mode on"

        case .runShortcut(let name):
            try await ShortcutsCLI.run(name)
            return "Ran “\(name)”"

        case .setWiFi(let on):
            guard let interface = CWWiFiClient.shared().interface() else { throw ActionExecutionError.wifi("no Wi-Fi hardware") }
            do {
                try interface.setPower(on)
            } catch {
                throw ActionExecutionError.wifi(error.localizedDescription)
            }
            return on ? "Wi-Fi on" : "Wi-Fi off"

        case .lockScreen:
            // The standard ⌃⌘Q "Lock Screen" shortcut.
            let source = CGEventSource(stateID: .hidSystemState)
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: isDown)
                event?.flags = [.maskCommand, .maskControl]
                event?.post(tap: .cghidEventTap)
            }
            return "Locked"

        case .sleepDisplay:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            try process.run()
            return "Display asleep"

        case .newFolder(let place, let name):
            return try await Places.newFolder(in: place, name: name)

        case .openPlace(let place):
            return try Places.open(place)

        case .makeNote(let text):
            try await AppleScriptRunner.run(
                "tell application \"Notes\" to make new note with properties {body:\(AppleScriptText.quoted(text))}",
                app: "Notes")
            return "Added a note"

        case .addReminder(let text):
            try await ReminderStore.add(text)
            return "Added a reminder"

        case .media(let key):
            MediaKeys.press(key)
            return switch key {
            case .playPause: "Play/pause"
            case .next: "Next track"
            case .previous: "Previous track"
            }

        case .screenshot(let kind):
            return try await Screenshots.take(kind, blocklist: blocklist)

        case .newFinderWindow:
            try await AppleScriptRunner.run("""
                tell application "Finder"
                    make new Finder window
                    activate
                end tell
                """, app: "Finder")
            return "Opened a Finder window"

        case .showDesktop:
            // Mission Control's own "show desktop" (the same as its keyboard shortcut).
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
            process.arguments = ["1"]
            try process.run()
            return "Showing the desktop"

        case .file(let action):
            return try await FileActions.run(action)
        }
    }
}

/// Finds installed apps by (fuzzy) name in the standard application folders.
enum AppLocator {
    private static var searchFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications", home.appending(path: "Applications").path,
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Installed apps by name ("System Settings" → its URL).
    static func installed() -> [String: URL] {
        var apps: [String: URL] = [:]
        for folder in searchFolders {
            let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in contents where url.pathExtension == "app" {
                apps[url.deletingPathExtension().lastPathComponent] = apps[url.deletingPathExtension().lastPathComponent] ?? url
            }
        }
        return apps
    }

    static func url(forAppNamed name: String) -> URL? {
        let apps = installed()
        guard let match = ActionCatalog.bestMatch(for: name, in: Array(apps.keys), threshold: 0.75) else { return nil }
        return apps[match]
    }
}

/// Default output device volume and mute through Core Audio — no permission needed.
enum SystemAudio {
    static func setVolume(_ level: Float) throws {
        var value = min(max(level, 0), 1)
        try set(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, value: &value)
    }

    static func setMuted(_ muted: Bool) throws {
        var value: UInt32 = muted ? 1 : 0
        try set(kAudioDevicePropertyMute, value: &value)
    }

    private static func set<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, value: inout T) throws {
        let device = try defaultOutputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else {
            throw ActionExecutionError.audio("this output device doesn't support it")
        }
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
        guard status == noErr else { throw ActionExecutionError.audio("error \(status)") }
    }

    private static func defaultOutputDevice() throws -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else { throw ActionExecutionError.audio("no output device") }
        return device
    }
}

/// Runs AppleScript off the main thread: the first use of System Events shows a
/// macOS permission prompt, which blocks the calling thread until answered.
enum AppleScriptRunner {
    /// `app` names the app being controlled, for the permission message.
    static func run(_ source: String, app: String = "System Events") async throws {
        let failure: String? = await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return nil }
            let number = error[NSAppleScript.errorNumber] as? Int
            if number == -1743 {
                return "ClickBait isn't allowed to control \(app). Turn it on in System Settings → Privacy & Security → Automation."
            }
            return error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(number ?? 0)"
        }.value
        if let failure { throw ActionExecutionError.script(failure) }
    }
}

/// Apple's `shortcuts` command-line tool.
enum ShortcutsCLI {
    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Names of the user's shortcuts, for the allow-list in Settings.
    static func list() async -> [String] {
        guard let output = try? await execute(["list"], timeout: .seconds(10)) else { return [] }
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func run(_ name: String) async throws {
        do {
            _ = try await execute(["run", name], timeout: .seconds(60))
        } catch let error as ActionExecutionError {
            throw error
        } catch {
            throw ActionExecutionError.shortcutFailed(name, error.localizedDescription)
        }
    }

    /// Runs the tool with arguments passed as an array (never through a shell).
    private static func execute(_ arguments: [String], timeout: Duration) async throws -> String {
        let name = arguments.last ?? ""
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()

            let deadline = ContinuousClock.now + timeout
            while process.isRunning {
                if ContinuousClock.now > deadline {
                    process.terminate()
                    throw ActionExecutionError.shortcutFailed(name, "it took too long")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ActionExecutionError.shortcutFailed(name, message.isEmpty ? "exit code \(process.terminationStatus)" : message)
            }
            return text
        }.value
    }
}

/// The keyboard's play/pause, next and previous keys, posted as system events so they
/// reach whatever is playing (Music, Spotify, a video in the browser).
enum MediaKeys {
    static func press(_ key: MediaKey) {
        // NX_KEYTYPE_PLAY, NX_KEYTYPE_NEXT, NX_KEYTYPE_PREVIOUS from IOKit's ev_keymap.h.
        let code: Int = switch key {
        case .playPause: 16
        case .next: 17
        case .previous: 18
        }
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// Screenshots the user asked for, saved where macOS saves its own.
enum Screenshots {
    @MainActor
    static func take(_ kind: ScreenshotKind, blocklist: AppBlocklist) async throws -> String {
        let folder = saveFolder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = folder.appending(path: "Screenshot \(formatter.string(from: Date())).png")

        switch kind {
        case .full:
            // ScreenCaptureKit, so ClickBait's own triangle and pills aren't in it.
            let capture = try await ScreenCapturer().captureDisplayUnderCursor(excluding: blocklist)
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw FileActionError.failed("couldn't save the screenshot")
            }
            CGImageDestinationAddImage(destination, capture.image, nil)
            guard CGImageDestinationFinalize(destination) else { throw FileActionError.failed("couldn't save the screenshot") }
        case .area, .window:
            // macOS's own picker; Esc cancels and leaves no file.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", kind == .area ? "-s" : "-W", file.path]
            try process.run()
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
            }
            guard FileManager.default.fileExists(atPath: file.path) else { return "Screenshot cancelled" }
        }
        let place = folder.standardizedFileURL == (try? Places.url(for: .desktop))?.standardizedFileURL ? "the Desktop" : folder.lastPathComponent
        return "Saved a screenshot to \(place)"
    }

    /// The folder set in the Screenshot app's Options, or the Desktop.
    private static func saveFolder() -> URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return (try? Places.url(for: .desktop)) ?? FileManager.default.homeDirectoryForCurrentUser
    }
}

/// Adds reminders through EventKit. Reminders are protected data (like Calendars), with
/// their own permission prompt — scripting the Reminders app was refused silently.
enum ReminderStore {
    enum Failure: LocalizedError {
        case notAllowed
        case noList

        var errorDescription: String? {
            switch self {
            case .notAllowed:
                "ClickBait isn't allowed to add reminders. Turn it on in System Settings → Privacy & Security → Reminders."
            case .noList: "There's no reminders list to add to. Open Reminders once to set one up."
            }
        }
    }

    static func add(_ title: String) async throws {
        let store = EKEventStore()
        // macOS asks once ("ClickBait would like to access your reminders"). Adding
        // needs full access; ClickBait never reads existing reminders.
        guard try await store.requestFullAccessToReminders() else { throw Failure.notAllowed }
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure.noList }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        try store.save(reminder, commit: true)
    }
}
