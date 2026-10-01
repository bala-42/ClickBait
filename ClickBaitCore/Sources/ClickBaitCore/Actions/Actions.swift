/// A direct order recognised in what the user said (see `CommandParser`).
public struct ActionRequest: Codable, Equatable, Sendable {
    public var name: String
    public var argument: String?

    public init(name: String, argument: String? = nil) {
        self.name = name
        self.argument = argument
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
    case moveIntoNewFolder
    /// Recoverable: Finder's Trash, never a permanent delete.
    case moveToTrash

    /// File orders only act while Finder is frontmost, so "delete this" in a text
    /// editor can never touch files.
    public static let requiredFrontmostApp = "com.apple.finder"
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
            "I can't do that yet. I can open or quit apps, change the volume, switch Dark Mode or Wi-Fi, lock the screen, work with files selected in Finder, and run the shortcuts you've allowed in Settings."
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
            return .success(.file(.moveIntoNewFolder))
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
