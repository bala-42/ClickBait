/// Recognises direct spoken orders in a transcript with plain rules — no model.
///
/// A local vision model proved unreliable at this (it missed real orders and acted on
/// questions like "how do I open Safari?"), and a rule is instant. Questions are never
/// orders. App names aren't checked here; the app verifies them and treats an unknown
/// name ("open the File menu") as a normal question instead.
public enum CommandParser {
    static let questionWords: Set<String> = [
        "how", "what", "where", "why", "when", "which", "who", "whats", "wheres", "hows",
        "is", "are", "does", "do", "did", "should", "will", "am", "was",
    ]
    /// Polite lead-ins that still make an order: "please open…", "can you open…".
    static let leadIns = [
        "hey clickbait", "clickbait", "please", "can you", "could you", "would you", "will you", "can u", "go ahead and", "now",
    ]

    public static func parse(_ transcript: String, allowedShortcuts: [String]) -> ActionRequest? {
        var words = normalize(transcript)
        guard !words.isEmpty else { return nil }

        // "Can I…?" / "How do I…?" are questions; "can you…" is a polite order.
        if words.count > 1, ["can", "could"].contains(words[0]), ["i", "we"].contains(words[1]) { return nil }
        words = strippingLeadIns(words)
        guard let first = words.first, !questionWords.contains(first) else { return nil }
        if words.last == "please" { words.removeLast() }
        let text = words.joined(separator: " ")

        if let action = volume(words) ?? appearance(text) ?? mute(text) ?? wifi(words) ?? system(text) { return action }
        if let action = apps(words, transcript: transcript) { return action }
        if let action = places(words, transcript: transcript) { return action }
        if let action = file(words, transcript: transcript) { return action }
        if let action = shortcut(words, allowedShortcuts: allowedShortcuts) { return action }
        if let action = app(words) { return action }
        return nil
    }

    /// Whether what was said is an order rather than a question — a model's proposed
    /// action is only considered for orders.
    public static func looksLikeOrder(_ transcript: String) -> Bool {
        var words = normalize(transcript)
        guard !words.isEmpty, !transcript.trimmingCharacters(in: .whitespaces).hasSuffix("?") else { return false }
        if words.count > 1, ["can", "could"].contains(words[0]), ["i", "we"].contains(words[1]) { return false }
        words = strippingLeadIns(words)
        guard let first = words.first else { return false }
        return !questionWords.contains(first) && !["i", "im", "my", "it", "its", "this", "that", "the"].contains(first)
    }

    /// The answer to "Go ahead?": true for yes, false for no, nil if it's neither.
    public static func confirmation(_ transcript: String) -> Bool? {
        let text = strippingLeadIns(normalize(transcript)).joined(separator: " ")
        let yes = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "do it", "go ahead", "confirm", "yes please", "please do",
                   "go", "yes do it", "sure go ahead", "ok do it", "okay do it"]
        let no = ["no", "nope", "cancel", "dont", "don't", "stop", "no thanks", "never mind", "nevermind", "no dont", "abort"]
        if yes.contains(text) { return true }
        if no.contains(text) { return false }
        return nil
    }

    // MARK: - Rules

    private static func volume(_ words: [String]) -> ActionRequest? {
        guard words.contains(where: { $0 == "volume" || $0 == "sound" }),
              let level = NumberWords.value(in: words), (0...100).contains(level)
        else { return nil }
        // Any order that names the volume and a level: "volume 30", "set the volume to
        // twenty", "turn the sound down to 10 percent".
        let verbs: Set<String> = ["volume", "set", "turn", "change", "put", "make", "sound"]
        guard let first = words.first, verbs.contains(first) else { return nil }
        return ActionRequest(name: "set_volume", argument: String(level))
    }

    private static func appearance(_ text: String) -> ActionRequest? {
        let dark = ["dark mode", "dark mode on", "turn on dark mode", "switch to dark mode", "enable dark mode", "go dark",
                    "use dark mode", "change to dark mode", "set dark mode"]
        let light = ["light mode", "light mode on", "turn on light mode", "switch to light mode", "enable light mode",
                     "turn off dark mode", "disable dark mode", "dark mode off", "use light mode", "change to light mode"]
        if dark.contains(text) { return ActionRequest(name: "dark_mode") }
        if light.contains(text) { return ActionRequest(name: "light_mode") }
        return nil
    }

    private static func mute(_ text: String) -> ActionRequest? {
        let objects = ["", " the sound", " sound", " the volume", " volume", " the audio", " audio", " my mac", " the mac"]
        if objects.contains(where: { text == "mute" + $0 }) { return ActionRequest(name: "mute") }
        if objects.contains(where: { text == "unmute" + $0 || text == "un mute" + $0 }) { return ActionRequest(name: "unmute") }
        if text == "turn the sound off" || text == "sound off" { return ActionRequest(name: "mute") }
        if text == "turn the sound on" || text == "sound on" { return ActionRequest(name: "unmute") }
        return nil
    }

    /// "turn on wifi", "wi-fi off", "disable wifi" (Whisper writes "Wi-Fi", "WiFi" or "wifi").
    private static func wifi(_ words: [String]) -> ActionRequest? {
        var joined = words.joined(separator: " ").replacingOccurrences(of: "wi fi", with: "wifi")
        joined = joined.replacingOccurrences(of: "the ", with: "")
        guard joined.contains("wifi") else { return nil }
        let on = ["turn on wifi", "turn wifi on", "wifi on", "enable wifi", "switch on wifi", "switch wifi on", "connect to wifi"]
        let off = ["turn off wifi", "turn wifi off", "wifi off", "disable wifi", "switch off wifi", "switch wifi off", "disconnect wifi"]
        if on.contains(joined) { return ActionRequest(name: "wifi_on") }
        if off.contains(joined) { return ActionRequest(name: "wifi_off") }
        return nil
    }

    private static func system(_ text: String) -> ActionRequest? {
        let lock = ["lock", "lock screen", "lock the screen", "lock my screen", "lock my mac", "lock the mac", "lock the computer",
                    "lock my computer"]
        let sleep = ["sleep display", "sleep the display", "turn off the display", "turn off the screen", "turn the screen off",
                     "turn the display off", "put the display to sleep", "put the screen to sleep", "screen off", "display off"]
        if lock.contains(text) { return ActionRequest(name: "lock_screen") }
        if sleep.contains(text) { return ActionRequest(name: "sleep_display") }
        return nil
    }

    /// Built-in apps and system conveniences: notes, reminders, media keys, screenshots,
    /// Finder windows, show desktop.
    private static func apps(_ words: [String], transcript: String) -> ActionRequest? {
        let text = words.joined(separator: " ")
        guard let verb = words.first else { return nil }

        // "make a note: call the dentist", "note that the meeting moved", "jot down buy milk"
        if words.contains("note") || (verb == "jot" && words.dropFirst().first == "down") {
            let noteVerbs: Set<String> = ["make", "create", "add", "take", "write", "new", "note", "jot", "start"]
            guard noteVerbs.contains(verb) else { return nil }
            return ActionRequest(name: "make_note", detail: SpokenContent.after(["note", "jot down"], in: transcript))
        }
        // "remind me to send the invoice", "add a reminder to call Sam", "set a reminder: dentist"
        if verb == "remind" || words.contains("reminder") {
            let reminderVerbs: Set<String> = ["remind", "add", "set", "create", "make", "new"]
            guard reminderVerbs.contains(verb) else { return nil }
            return ActionRequest(name: "add_reminder", detail: SpokenContent.after(["remind me", "reminder"], in: transcript))
        }

        // Media keys: "play", "pause the music", "resume", "next song", "skip this track", "previous track"
        let playPause = ["play", "pause", "resume", "play music", "pause music", "play the music", "pause the music",
                         "stop the music", "stop music", "play the song", "pause the song", "pause this", "play this",
                         "pause the video", "play the video", "resume the music", "resume playback", "pause playback"]
        if playPause.contains(text) { return ActionRequest(name: "media", argument: MediaKey.playPause.rawValue) }
        let track: Set<String> = ["song", "track", "video", "one"]
        if ["next", "skip"].contains(verb), words.count <= 4, words.contains(where: track.contains) || text == "skip" || text == "next" {
            return ActionRequest(name: "media", argument: MediaKey.next.rawValue)
        }
        if verb == "previous" || text.hasPrefix("go back a") || text == "last song" || text == "last track",
           words.count <= 4, words.contains(where: track.contains) || verb == "previous" {
            return ActionRequest(name: "media", argument: MediaKey.previous.rawValue)
        }

        // "take a screenshot", "screenshot this window", "screenshot an area"
        if words.contains("screenshot") || words.contains("screengrab") || text.hasPrefix("capture the screen") {
            guard ["take", "screenshot", "grab", "capture", "make", "screengrab"].contains(verb) else { return nil }
            let kind: ScreenshotKind = words.contains("window") ? .window
                : (words.contains("area") || words.contains("part") || words.contains("region") || words.contains("selection")) ? .area
                : .full
            return ActionRequest(name: "screenshot", argument: kind.rawValue)
        }

        if words.contains("finder"), words.contains("window"), words.contains("new") {
            return ActionRequest(name: "finder_window")
        }
        if ["show desktop", "show the desktop", "show my desktop", "hide all windows", "clear the screen"].contains(text) {
            return ActionRequest(name: "show_desktop")
        }
        return nil
    }

    /// Folders by name: make one, open one, move or copy the selection to one, rename.
    private static func places(_ words: [String], transcript: String) -> ActionRequest? {
        guard let verb = words.first else { return nil }
        let selection: Set<String> = ["these", "this", "them", "it", "that", "selected", "selection", "files", "file", "items",
                                      "pdfs", "images", "photos", "pictures", "screenshots", "documents", "videos"]
        let rest = words.dropFirst()
        let refersToSelection = rest.contains(where: selection.contains)
        let name = SpokenName.after(["called", "named"], in: transcript)

        // "rename this to Invoice March"
        if verb == "rename" {
            return ActionRequest(name: "rename", detail: SpokenName.renameTarget(in: transcript))
        }

        // "make a new folder (in Downloads) (called Receipts)" — but "put these in a
        // new folder" moves the selection into one.
        let pointsAtSelection = rest.contains(where: ["these", "this", "them", "it", "that", "selected", "selection"].contains)
        if rest.contains("folder"), ["make", "create", "new", "add"].contains(verb), !pointsAtSelection {
            let place = placeAfterPreposition(words)
            return ActionRequest(name: "make_folder", argument: place?.rawValue, detail: name)
        }
        // "a (new) folder" makes one; "the new folder" / "the receipts folder" is an existing one.
        let text = words.joined(separator: " ")
        let intoAFolder = text.contains("a new folder") || text.contains("a folder") || text.contains("new folder called")
            || text.contains("new folder named")
        if ["put", "move", "group"].contains(verb), refersToSelection, intoAFolder,
           placeAfterPreposition(words) == nil, !rest.contains("trash"), !rest.contains("bin") {
            return ActionRequest(name: "new_folder", detail: name)
        }

        // "open Downloads", "go to my Documents folder", "show me the Desktop folder"
        if ["open", "show", "go"].contains(verb) {
            var after = rest
            while let first = after.first, ["me", "to", "up"].contains(first) { after = after.dropFirst() }
            if let (place, used) = Place.named(at: after, strict: true), after.count == used {
                // "show desktop" hides windows; only "show the Desktop folder" opens it.
                if verb == "show", place == .desktop, !after.contains("folder") { return nil }
                return ActionRequest(name: "open_place", argument: place.rawValue)
            }
            return nil
        }

        // "move these to Documents", "copy this to the Desktop"
        if ["move", "copy", "put", "send"].contains(verb), refersToSelection, !rest.contains("trash"), !rest.contains("bin") {
            let name = verb == "copy" ? "copy_to" : "move_to"
            if let place = placeAfterPreposition(words) { return ActionRequest(name: name, argument: place.rawValue) }
            // "move these into Receipts", "put them in the new folder" — a folder next to them.
            if let target = SpokenName.after(["into", "inside", "to", "in"], in: transcript) {
                let folder = FolderReference.clean(target)
                if !folder.isEmpty, !["a folder", "folder"].contains(folder.lowercased()) {
                    return ActionRequest(name: name, argument: folder)
                }
            }
        }
        return nil
    }

    /// The place after "in/on/to/into…": "in Downloads", "to the Desktop", "into my documents folder".
    private static func placeAfterPreposition(_ words: [String]) -> Place? {
        for (index, word) in words.enumerated() where ["in", "on", "to", "into", "inside", "onto"].contains(word) {
            if let (place, _) = Place.named(at: words[(index + 1)...], strict: false) { return place }
        }
        return nil
    }

    /// Orders about "these/this/the selected files". The app only runs them while
    /// Finder is frontmost (see `FileAction.requiredFrontmostApp`).
    private static func file(_ words: [String], transcript: String) -> ActionRequest? {
        let references: Set<String> = ["these", "this", "them", "it", "selected", "selection", "files", "file", "items",
                                       "pdfs", "pdf", "images", "photos", "pictures", "screenshots", "documents", "folder", "folders",
                                       "videos", "video", "movies"]
        guard let verb = words.first, words.contains(where: references.contains) || words.count == 1 else { return nil }
        let rest = Set(words.dropFirst())

        // "make these smaller", "reduce the size of this", "shrink them", "optimise these images"
        let shrinkVerbs: Set<String> = ["shrink", "reduce", "downsize", "optimise", "optimize", "minify", "lighten"]
        if shrinkVerbs.contains(verb) || (verb == "make" && (rest.contains("smaller") || rest.contains("lighter"))) {
            return ActionRequest(name: "shrink")
        }

        switch verb {
        case "compress", "zip":
            return ActionRequest(name: "compress")
        case "merge", "combine", "join":
            return ActionRequest(name: "merge")
        case "convert", "make", "turn", "save", "export":
            if rest.contains("jpeg") || rest.contains("jpg") || rest.contains("jpegs") || rest.contains("jpgs") {
                return ActionRequest(name: "convert_images", argument: "jpeg")
            }
            if rest.contains("png") || rest.contains("pngs") { return ActionRequest(name: "convert_images", argument: "png") }
            return nil
        case "put", "move", "group":
            if rest.contains("trash") || rest.contains("bin") { return ActionRequest(name: "trash") }
            if rest.contains("folder") { return ActionRequest(name: "new_folder", detail: SpokenName.after(["called", "named"], in: transcript)) }
            return nil
        case "delete", "trash", "remove", "bin":
            return words.count == 1 ? nil : ActionRequest(name: "trash")
        default:
            return nil
        }
    }

    /// "run Focus Time", "run my Focus Time shortcut", or just an allowed shortcut's name.
    private static func shortcut(_ words: [String], allowedShortcuts: [String]) -> ActionRequest? {
        guard !allowedShortcuts.isEmpty else { return nil }
        var rest = words
        let hasVerb = ["run", "start", "do", "trigger", "launch"].contains(rest.first ?? "")
        if hasVerb { rest.removeFirst() }
        rest = rest.filter { !["my", "the", "shortcut"].contains($0) }
        let name = rest.joined(separator: " ")
        guard !name.isEmpty, let match = ActionCatalog.bestMatch(for: name, in: allowedShortcuts, threshold: hasVerb ? 0.8 : 0.95)
        else { return nil }
        return ActionRequest(name: "run_shortcut", argument: match)
    }

    private static func app(_ words: [String]) -> ActionRequest? {
        guard let verb = words.first, words.count > 1 else { return nil }
        let action: String
        switch verb {
        case "open", "launch", "start": action = "open_app"
        case "quit", "close", "exit": action = "quit_app"
        default: return nil
        }
        var rest = Array(words.dropFirst())
        if rest.first == "up" { rest.removeFirst() }  // "open up Safari"
        if rest.first == "the" { rest.removeFirst() }
        if rest.last == "app" || rest.last == "application" { rest.removeLast() }
        guard !rest.isEmpty else { return nil }
        return ActionRequest(name: action, argument: rest.joined(separator: " "))
    }

    // MARK: - Text

    /// Lowercased words with punctuation removed ("Open Safari, please!" → open safari please).
    static func normalize(_ text: String) -> [String] {
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return Character(scalar) }
            if scalar == "'" || scalar == "’" { return "\u{0}" }  // "what's" → "whats"
            return " "
        }
        return String(scalars).replacingOccurrences(of: "\u{0}", with: "").split(separator: " ").map(String.init)
    }

    private static func strippingLeadIns(_ words: [String]) -> [String] {
        var words = words
        var changed = true
        while changed {
            changed = false
            for leadIn in leadIns {
                let parts = leadIn.split(separator: " ").map(String.init)
                if words.count > parts.count, Array(words.prefix(parts.count)) == parts {
                    words.removeFirst(parts.count)
                    changed = true
                }
            }
        }
        return words
    }
}

/// "20", "twenty", "twenty five", "a hundred" → numbers (0–100), for volume levels.
enum NumberWords {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    static func value(in words: [String]) -> Int? {
        for (index, word) in words.enumerated() {
            if let number = Int(word) { return number }
            if word == "hundred" { return 100 }
            if let ten = tens[word] {
                if index + 1 < words.count, let unit = units[words[index + 1]], unit < 10 { return ten + unit }
                return ten
            }
            if let unit = units[word] { return unit }
        }
        return nil
    }
}
