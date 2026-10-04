/// A direct order recognised in what the user said (see `CommandParser`).
public struct ActionRequest: Codable, Equatable, Sendable {
    public var name: String
    public var argument: String?
    /// A name as the user said it ("called Receipts", "rename this to …"), case kept.
    public var detail: String?

    public init(name: String, argument: String? = nil, detail: String? = nil) {
        self.name = name
        self.argument = argument
        self.detail = detail
    }
}

/// An action that passed validation and is ready to run.
public enum ResolvedAction: Equatable, Sendable {
    case openApp(String)
    case quitApp(String)
    case setVolume(percent: Int)
    case setMuted(Bool)
    case setDarkMode(Bool)
    case runShortcut(String)
    case setWiFi(Bool)
    case lockScreen
    case sleepDisplay
    /// An empty folder in `place`, or (nil) in the front Finder window's folder or on
    /// the Desktop. Unnamed: "untitled folder", like Finder.
    case newFolder(in: Place?, name: String?)
    case openPlace(Place)
    /// A new note in Notes with this text.
    case makeNote(String)
    /// A new reminder in Reminders' default list.
    case addReminder(String)
    /// The keyboard's media keys, so it works with whatever is playing.
    case media(MediaKey)
    case screenshot(ScreenshotKind)
    case newFinderWindow
    case showDesktop
    /// Acts on the files selected in Finder.
    case file(FileAction)
}

/// Things ClickBait can do with the files selected in Finder. Every action except
/// `moveToTrash` leaves the originals untouched and creates something new.
public enum FileAction: Equatable, Sendable {
    case compress
    /// PDFs and images become one PDF; text files become one text file.
    case merge
    case convertImages(to: ImageFormat)
    case moveIntoNewFolder(name: String?)
    /// Into a named place; nothing is ever overwritten (clashing names get a number).
    case moveTo(Place)
    case copyTo(Place)
    /// Into a folder next to the selected files, by name ("Receipts", or "new folder"
    /// for the one ClickBait just made).
    case moveToFolder(String)
    case copyToFolder(String)
    /// Exactly one selected item; its extension is kept if the new name has none.
    case rename(to: String)
    /// Recoverable: Finder's Trash, never a permanent delete.
    case moveToTrash
    /// Smaller copies of images, PDFs and videos (originals untouched).
    case shrink

    /// File orders only act while Finder is frontmost, so "delete this" in a text
    /// editor can never touch files.
    public static let requiredFrontmostApp = "com.apple.finder"
}

public enum MediaKey: String, Equatable, Sendable {
    case playPause = "play_pause"
    case next
    case previous
}

public enum ScreenshotKind: String, Equatable, Sendable {
    /// The whole screen, saved without asking.
    case full
    /// macOS's crosshair: drag out an area.
    case area
    /// macOS's window picker.
    case window
}

public enum ImageFormat: String, Equatable, Sendable {
    case jpeg
    case png
}

public enum ActionError: Error, Equatable, Sendable {
    case unknown(String)
    case missingArgument(String)
    case invalidArgument(String)
    case shortcutNotAllowed(String)

    /// Spoken and shown to the user.
    public var message: String {
        switch self {
        case .unknown:
            "I can't do that yet. I can open or quit apps, change the volume, switch Dark Mode or Wi-Fi, lock the screen, make and open folders, work with files selected in Finder, make notes and reminders, control what's playing, take screenshots, and run the shortcuts you've allowed in Settings."
        case .missingArgument(let action):
            "I didn't catch what to \(action)."
        case .invalidArgument(let detail):
            "I couldn't do that: \(detail)."
        case .shortcutNotAllowed(let name):
            "The shortcut “\(name)” isn't allowed. Tick it in Settings → Commands first."
        }
    }
}

/// The actions ClickBait can perform, and the checks that run before any of them.
/// Shortcuts must be on the user's allowed list — the list is the permission, so
/// allowed shortcuts run on command with no further prompt.
public enum ActionCatalog {
    public static func resolve(_ request: ActionRequest, allowedShortcuts: [String]) -> Result<ResolvedAction, ActionError> {
        let name = request.name.lowercased().trimmingCharacters(in: .whitespaces)
        let argument = request.argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A spoken name must be usable as one file name.
        let detail = request.detail.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let detailIsFileName = !["make_note", "add_reminder"].contains(name)
        if detailIsFileName, let detail, SpokenName.validated(detail) == nil {
            return .failure(.invalidArgument("“\(detail)” can't be used as a name"))
        }
        let place = Place(rawValue: argument.lowercased())

        switch name {
        case "open_app", "quit_app":
            guard !argument.isEmpty else { return .failure(.missingArgument(name == "open_app" ? "open" : "quit")) }
            return .success(name == "open_app" ? .openApp(argument) : .quitApp(argument))
        case "set_volume":
            let digits = argument.filter(\.isNumber)
            guard let value = Int(digits) else { return .failure(.invalidArgument("the volume should be a number from 0 to 100")) }
            return .success(.setVolume(percent: min(max(value, 0), 100)))
        case "mute":
            return .success(.setMuted(true))
        case "unmute":
            return .success(.setMuted(false))
        case "dark_mode":
            return .success(.setDarkMode(true))
        case "light_mode":
            return .success(.setDarkMode(false))
        case "wifi_on":
            return .success(.setWiFi(true))
        case "wifi_off":
            return .success(.setWiFi(false))
        case "lock_screen":
            return .success(.lockScreen)
        case "sleep_display":
            return .success(.sleepDisplay)
        case "compress":
            return .success(.file(.compress))
        case "merge":
            return .success(.file(.merge))
        case "convert_images":
            guard let format = ImageFormat(rawValue: argument.lowercased() == "jpg" ? "jpeg" : argument.lowercased()) else {
                return .failure(.invalidArgument("I can convert images to JPEG or PNG"))
            }
            return .success(.file(.convertImages(to: format)))
        case "new_folder":
            return .success(.file(.moveIntoNewFolder(name: detail)))
        case "make_folder":
            guard argument.isEmpty || place != nil else { return .failure(.invalidArgument("I don't know the folder “\(argument)”")) }
            return .success(.newFolder(in: place, name: detail))
        case "open_place":
            guard let place else { return .failure(.missingArgument("open")) }
            return .success(.openPlace(place))
        case "move_to", "copy_to":
            let moving = name == "move_to"
            if let place { return .success(.file(moving ? .moveTo(place) : .copyTo(place))) }
            guard !argument.isEmpty else { return .failure(.missingArgument(moving ? "move them to" : "copy them to")) }
            guard let folder = SpokenName.validated(FolderReference.clean(argument)) else {
                return .failure(.invalidArgument("“\(argument)” isn't a folder name I can use"))
            }
            return .success(.file(moving ? .moveToFolder(folder) : .copyToFolder(folder)))
        case "make_note", "add_reminder":
            // Note and reminder text is content, not a file name: only needs to be there.
            guard let text = request.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .failure(.missingArgument(name == "make_note" ? "write in the note" : "remind you about"))
            }
            return .success(name == "make_note" ? .makeNote(text) : .addReminder(text))
        case "media":
            guard let key = MediaKey(rawValue: argument) else { return .failure(.invalidArgument("unknown media key")) }
            return .success(.media(key))
        case "screenshot":
            return .success(.screenshot(ScreenshotKind(rawValue: argument) ?? .full))
        case "finder_window":
            return .success(.newFinderWindow)
        case "show_desktop":
            return .success(.showDesktop)
        case "rename":
            guard let detail else { return .failure(.missingArgument("rename it to")) }
            return .success(.file(.rename(to: detail)))
        case "shrink":
            return .success(.file(.shrink))
        case "trash":
            return .success(.file(.moveToTrash))
        case "run_shortcut":
            guard !argument.isEmpty else { return .failure(.missingArgument("run")) }
            guard let match = bestMatch(for: argument, in: allowedShortcuts) else {
                return .failure(.shortcutNotAllowed(argument))
            }
            return .success(.runShortcut(match))
        default:
            return .failure(.unknown(request.name))
        }
    }

    /// Actions that change or remove things the user can't simply undo by looking: they
    /// run straight away only for clear, rule-recognised orders; a model's proposal
    /// asks first.
    public static func needsConfirmation(_ action: ResolvedAction) -> Bool {
        switch action {
        case .quitApp, .runShortcut, .setWiFi(false), .lockScreen, .sleepDisplay: true
        case .file(let file):
            switch file {
            case .moveToTrash, .moveTo, .moveToFolder, .rename, .moveIntoNewFolder: true
            case .compress, .merge, .convertImages, .shrink, .copyTo, .copyToFolder: false  // only make new files
            }
        default: false
        }
    }

    /// The question asked before a confirmed action ("Move the selected files to Documents?").
    public static func confirmationQuestion(for action: ResolvedAction, fileCount: Int?) -> String {
        let files = fileCount.map { $0 == 1 ? "the selected item" : "the \($0) selected items" } ?? "the selected items"
        return switch action {
        case .quitApp(let name): "Quit \(name)?"
        case .runShortcut(let name): "Run the shortcut “\(name)”?"
        case .setWiFi: "Turn Wi-Fi off?"
        case .lockScreen: "Lock the screen?"
        case .sleepDisplay: "Turn off the display?"
        case .file(.moveToTrash): "Move \(files) to the Trash?"
        case .file(.moveTo(let place)): "Move \(files) to \(place.displayName)?"
        case .file(.moveToFolder(let folder)): "Move \(files) into “\(folder)”?"
        case .file(.rename(let name)): "Rename \(files) to “\(name)”?"
        case .file(.moveIntoNewFolder(let name)): "Move \(files) into a new folder\(name.map { " called “\($0)”" } ?? "")?"
        default: "Go ahead?"
        }
    }

    /// The allowed name that best matches what the model (or Whisper) produced.
    public static func bestMatch(for name: String, in candidates: [String], threshold: Double = 0.8) -> String? {
        candidates
            .map { ($0, LabelMatcher.similarity(name, $0)) }
            .filter { $0.1 >= threshold }
            .max { $0.1 < $1.1 }?
            .0
    }
}

/// Names for files ClickBait creates, never overwriting anything.
public enum OutputName {
    /// "Merged.pdf", then "Merged 2.pdf", "Merged 3.pdf"… — like Finder.
    public static func unique(base: String, extension ext: String, existing: Set<String>) -> String {
        let suffix = ext.isEmpty ? "" : "." + ext
        var candidate = base + suffix
        var number = 2
        while existing.contains(candidate) {
            candidate = "\(base) \(number)\(suffix)"
            number += 1
        }
        return candidate
    }
}
