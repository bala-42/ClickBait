import Foundation

/// One step of a guided tutorial: what to click (as named on screen) and what to tell
/// the user.
public struct TutorialStep: Codable, Equatable, Sendable {
    /// The on-screen name of what to click ("File", "Export as PDF…", "Save").
    public var target: String
    /// A short instruction ("Open the File menu").
    public var instruction: String
    /// The app the click happens in ("Notes"), when the task spans apps. ClickBait
    /// switches to it (green) before pointing.
    public var app: String?
    /// This step is the menu item that opens `app` ("System Settings…" for System
    /// Settings): after clicking it, the app is on its way — no need to switch there.
    public func opensApp(_ app: String) -> Bool {
        TutorialPlan.withoutEllipsis(target).caseInsensitiveCompare(app) == .orderedSame
    }

    /// What to type into `target` ("youtube.com"), for a typing step; nil for a click.
    public var typing: String?

    public init(target: String, instruction: String, app: String? = nil, typing: String? = nil) {
        self.target = target
        self.instruction = instruction
        self.app = app
        self.typing = typing
    }

    /// A keyboard shortcut to press ("⌘C", "Command+V") rather than something to click.
    public var isShortcut: Bool {
        target.range(of: #"^\s*(?:[⌘⌥⌃⇧]+\s*\S{1,6}|(?:cmd|command|ctrl|control|option|shift)\s*[+-]\s*\S{1,6})\s*$"#,
                     options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A copy or cut shortcut: done once the clipboard changes.
    public var copiesToClipboard: Bool {
        isShortcut && target.range(of: #"[+⌘\s-](?:c|x)\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A typing step whose text is a web address ("youtube.com"): its host, to recognise
    /// the page once it's open. Nil for search text.
    public var typedHost: String? {
        guard let typing, let address = PageAddress.fromAddressBar(typing),
              let host = URL(string: address)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A how-to turned into steps to walk the user through on their own screen.
public struct TutorialPlan: Equatable, Sendable {
    /// One sentence saying what they'll do ("Here's how to export it as a PDF.").
    public var intro: String
    public var steps: [TutorialStep]
    /// The app the task has to be done in, when it isn't the one in front ("Safari"
    /// while in Notes). ClickBait opens it and plans the steps there.
    public var app: String?

    public static let maxSteps = 10
    static let maxInstructionLength = 160

    public init(intro: String, steps: [TutorialStep], app: String? = nil) {
        self.intro = intro
        self.steps = steps
        self.app = app
    }

    /// More than one click: worth walking through. A single step is answered by pointing.
    public var isTutorial: Bool { steps.count >= 2 }

    /// The plan in a reply to `Prompt.tutorialSystem` (possibly with no steps: the
    /// intro then says why it can't be done here).
    public static func parse(_ raw: String) -> TutorialPlan? {
        guard let data = firstObject(in: raw)?.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawSteps = object["steps"] as? [[String: Any]]
        else { return nil }
        let steps = rawSteps.compactMap { entry -> TutorialStep? in
            guard let target = (entry["target"] as? String).map(cleanTarget), !target.isEmpty else { return nil }
            let instruction = cleanInstruction(entry["instruction"] as? String ?? "")
            // A model reasoning inside a step ("Wait, the instruction says…") broke the plan.
            guard instruction.count <= maxInstructionLength, target.count <= 80 else { return nil }
            let app = (entry["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var typing = (entry["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // "type": "menu" / "button" is the model naming the kind of thing, not text.
            // "type": "menu" / "menuItem" / "keyboard" is the model naming the kind of step, not text.
            if let typed = typing?.lowercased().filter(\.isLetter),
               ["menu", "button", "click", "menuitem", "field", "text", "tab", "keyboard", "shortcut", "key", "press", "keypress",
                "type", "select", "choose", "menubar", "menubaritem", "textfield", "checkbox", "popupbutton", "link", "row",
                "item", "option"].contains(typed) || typed.hasPrefix("ax") { typing = nil }
            if typing?.isEmpty ?? true { typing = typedText(in: instruction) }  // "Type youtube.com, then press Return"
            return TutorialStep(target: target, instruction: instruction.isEmpty ? "Click \(target)" : instruction,
                                app: (app?.isEmpty ?? true) ? nil : app, typing: typing)
        }
        // "Bookmarks ▸ Add Bookmark…" as one target: open the menu, then choose the item.
        let split = steps.flatMap { step -> [TutorialStep] in
            let path = step.target.components(separatedBy: "▸").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard path.count >= 2 else { return [step] }
            var opened = path.dropLast().map { TutorialStep(target: $0, instruction: "Open \($0)", app: step.app) }
            opened[0].instruction = "Open the \(path[0]) menu"
            var item = step
            item.target = path.last!
            if item.instruction.range(of: "▸") != nil || item.instruction.isEmpty { item.instruction = "Choose \(item.target)" }
            return opened + [item]
        }
        let intro = cleanInstruction(object["speech"] as? String ?? "")
        // Padding a small model adds when it runs out of real steps: the same target
        // again (from anywhere earlier in the plan — a loop).
        var seen = Set<String>()
        // Typing different things into the same field isn't a repeat.
        let distinct = split.filter {
            seen.insert($0.target.lowercased().replacingOccurrences(of: "...", with: "…") + "|" + ($0.typing ?? "")).inserted
        }
        let app = (object["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TutorialPlan(intro: intro, steps: Array(distinct.prefix(maxSteps)), app: (app?.isEmpty ?? true) ? nil : app)
    }

    /// A small model writes "Open the History menu and choose Clear History…" as one
    /// step. When a step opens a menu and the plan's words name an item that really is in
    /// that menu (`outline`: "History ▸ Clear History…"), the item becomes the next step.
    public func expandingMenus(using outline: [String]) -> TutorialPlan {
        guard !outline.isEmpty else { return self }
        let entries = outline.map { $0.components(separatedBy: " ▸ ") }.filter { $0.count >= 2 }
        let menus = Set(entries.map { $0[0].lowercased() })
        var expanded: [TutorialStep] = []
        for (index, step) in steps.enumerated() {
            expanded.append(step)
            guard menus.contains(step.target.lowercased()) else { continue }
            let next = index + 1 < steps.count ? steps[index + 1].target.lowercased() : nil
            let words = ImpliedPointer.normalized(step.instruction + " " + intro)
            // The longest item of this menu that the words mention.
            let item = entries
                .filter { $0[0].lowercased() == step.target.lowercased() }
                .map { $0[1] }
                .filter { ImpliedPointer.normalized($0).count >= 3 && words.contains(ImpliedPointer.normalized($0)) }
                .max { $0.count < $1.count }
            if let item, item.lowercased() != next {
                expanded.append(TutorialStep(target: item, instruction: "Choose \(item)"))
            }
        }
        var plan = self
        plan.steps = Array(expanded.prefix(Self.maxSteps))
        return plan
    }

    /// Separates "open that app" from the clicks, and gives every step the app it happens
    /// in. ClickBait opens and switches apps itself (green), so "Open Safari" / "Switch to
    /// Notes" steps are dropped and the steps after them belong to that app. `app` becomes
    /// the first step's app when it isn't the one in front (opened before the lesson starts).
    public func separatingSetup(frontmostApp: String?, isInstalledApp: (String) -> Bool) -> TutorialPlan {
        var plan = self
        let front = frontmostApp?.lowercased()
        var current = app.flatMap(Self.realApp) ?? frontmostApp
        var kept: [TutorialStep] = []
        for (position, var step) in steps.enumerated() {
            let switching = ["open", "launch", "switch", "go", "return", "back", "start", "click", "choose"]
            let verb = ImpliedPointer.normalized(step.instruction).split(separator: " ").first.map(String.init) ?? ""
            // "Open the Safari menu" is the app's own menu, not opening the app.
            let isMenu = ImpliedPointer.normalized(step.instruction).split(separator: " ").contains("menu")
            // "Apple menu → System Settings…": a menu item that opens an app. The user is shown
            // it (pointing, like any menu item); the steps after it happen in that app.
            let appTarget = Self.withoutEllipsis(step.target)
            let afterAppleMenu = kept.last.map { Self.appleMenuNames.contains($0.target.lowercased()) } ?? false
            if isInstalledApp(appTarget), appTarget != step.target || afterAppleMenu {
                step.app = current
                kept.append(step)
                current = Self.realApp(appTarget) ?? appTarget
                continue
            }
            if isInstalledApp(step.target), !isMenu, position == 0 || switching.contains(verb) || step.target.lowercased() == front {
                current = step.target  // "Open Safari": ClickBait does that
                continue
            }
            if let named = step.app.flatMap(Self.realApp) { current = named }
            step.app = current
            kept.append(step)
        }
        plan.steps = kept
        plan.app = kept.first?.app ?? (kept.isEmpty ? current : nil)
        if plan.app?.lowercased() == front { plan.app = nil }
        return plan
    }

    /// The Apple menu as plans name it.
    public static let appleMenuNames: Set = ["apple", "apple menu", "", "apple logo"]

    /// "System Settings…" → "System Settings".
    public static func withoutEllipsis(_ target: String) -> String {
        var name = target.trimmingCharacters(in: .whitespaces)
        for suffix in ["…", "..."] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Whether the menu item a step's target was found at ("Safari ▸ Clear History…") is one an
    /// earlier step of this plan already chose. A later step is never back there: Safari's
    /// dialog button "Clear History" matched the item just used, and the walkthrough sent the
    /// user into the menu to clear history a second time.
    public func choseEarlier(_ menuPath: [String], before index: Int) -> Bool {
        guard let item = menuPath.last else { return false }
        let name = Self.withoutEllipsis(item)
        return steps.prefix(max(0, min(index, steps.count))).contains {
            Self.withoutEllipsis($0.target).caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// The way into System Settings that works from any app: the Apple menu, then
    /// "System Settings…". Shown (pointed at), not done for the user; no model needed.
    /// `route` (from `SystemSettingsMap`) continues inside System Settings: the page in
    /// the sidebar, then what to click on it.
    public static func systemSettingsByAppleMenu(from front: String?, route: [String] = []) -> TutorialPlan {
        var steps: [TutorialStep] = []
        if front?.caseInsensitiveCompare("System Settings") != .orderedSame {
            // No app: the Apple menu is the same in every app. Tied to the app in front when
            // asked, a switch of front app mid-way made the tutorial "switch back" to it.
            steps += [
                TutorialStep(target: "Apple", instruction: "Click the Apple menu"),
                TutorialStep(target: "System Settings…", instruction: "Choose System Settings…"),
            ]
        }
        steps += route.map { TutorialStep(target: $0, instruction: "Click \($0)", app: "System Settings") }
        let intro = route.isEmpty
            ? "Open the Apple menu, then choose System Settings."
            : "In System Settings: " + route.joined(separator: " → ") + "."
        return TutorialPlan(intro: intro, steps: steps)
    }

    /// The app name as it is on today's Macs, or nil for ClickBait itself (the model sees
    /// its chat in front and names it).
    static func realApp(_ name: String) -> String? {
        switch name.lowercased() {
        case "clickbait": nil
        case "system preferences": "System Settings"
        default: name
        }
    }

    /// The apps the plan uses, in order of first use.
    public var apps: [String] {
        var seen = Set<String>()
        return steps.compactMap(\.app).filter { seen.insert($0.lowercased()).inserted }
    }

    /// What's left after `done` steps, from a follow-up plan — or nil when that plan just
    /// starts the task over (its first step is one already done): the task is finished,
    /// and walking it again would e.g. clear another hour of history.
    public static func remaining(_ more: TutorialPlan, after done: [TutorialStep]) -> [TutorialStep]? {
        let doneTargets = Set(done.map { $0.target.lowercased() })
        guard let first = more.steps.first, !doneTargets.contains(first.target.lowercased()) else { return nil }
        let rest = more.steps.filter { !doneTargets.contains($0.target.lowercased()) }
        return rest.isEmpty ? nil : rest
    }

    /// "Type youtube.com, then press Return" → "youtube.com"; "Type 'lofi beats'" → "lofi
    /// beats". Nil when the instruction isn't about typing.
    static func typedText(in instruction: String) -> String? {
        guard let match = instruction.range(of: #"^\s*(?:type|enter)\s+(.+?)(?:\s*,?\s*(?:then|and)\s+press\s+return.*|\s+(?:in|into)\s+the\s+.*)?\.?$"#,
                                            options: [.regularExpression, .caseInsensitive]) else { return nil }
        var text = String(instruction[match])
        text = text.replacingOccurrences(of: #"^\s*(?:type|enter)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"(?:\s*,?\s*(?:then|and)\s+press\s+return.*|\s+(?:in|into)\s+the\s+.*)?\.?$"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "'\"“”‘’ "))
        let vague: Set<String> = ["it", "the link", "the address", "the url", "the page's link", "your search", "the text"]
        return text.isEmpty || vague.contains(text.lowercased()) ? nil : text
    }

    /// What the lavender pill and the chat show: no positions or element-list leftovers.
    /// `Click button "Share" at (980, 52)` → `Click Share`.
    static func cleanInstruction(_ raw: String) -> String {
        var text = raw
        for pattern in [#"\s*\bat\s*\(\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)"#,  // at (980, 52)
                        #"\s*\(\s*(?:id|element)\s*:?\s*\d+\s*\)"#,                       // (id: 7)
                        #"\s*\b(?:element|id)\s+#?\d+\b"#] {                              // element 7
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = CoordinateScrubber.scrub(text).text
        // `button "Share"` / `menu item "Clear History…"` → the name alone.
        text = text.replacingOccurrences(
            of: #"\b(?:button|menu item|menu|pop-up menu|checkbox|radio button|text field|tab|link|row)\s+["“]([^"”]+)["”]"#,
            with: "$1", options: [.regularExpression, .caseInsensitive])
        return text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `button "New Note" at (300, 60)` → `New Note` (models copy element-list lines).
    static func cleanTarget(_ raw: String) -> String {
        var target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = target.firstIndex(where: { $0 == "\"" || $0 == "“" }),
           let close = target[target.index(after: open)...].firstIndex(where: { $0 == "\"" || $0 == "”" }) {
            target = String(target[target.index(after: open)..<close])
        }
        target = target.replacingOccurrences(of: #"\s*at\s*\(\s*\d+\s*,\s*\d+\s*\)"#, with: "", options: .regularExpression)
        for suffix in [" menu item", " menu", " button", " tab"] where target.lowercased().hasSuffix(suffix) && target.count > suffix.count + 1 {
            target = String(target.dropLast(suffix.count))
        }
        return target.trimmingCharacters(in: CharacterSet(charactersIn: "'\"“”‘’ ").union(.whitespaces))
    }

    private static func firstObject(in raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        return String(raw[start...end])
    }

    /// The steps as the chat shows them, with ticks for those done.
    /// Across apps, each app's steps start with "In Notes:".
    public func checklist(done: Int) -> String {
        let spansApps = apps.count > 1
        var lines: [String] = []
        for (index, step) in steps.enumerated() {
            if spansApps, let app = step.app, index == 0 || steps[index - 1].app?.lowercased() != app.lowercased() {
                lines.append("In \(app):")
            }
            lines.append((index < done ? "✓ " : "\(index + 1). ") + step.instruction)
        }
        return lines.joined(separator: "\n")
    }
}

/// Questions that ask to be shown how to do something with more than one click.
public enum TutorialQuestion {
    static let phrases = ["how do i", "how can i", "how to", "how would i", "walk me through", "teach me",
                          "guide me", "tutorial", "steps to", "what are the steps"]

    /// "Show me the X", "show me where X is": asks to be shown where to click, blue pointing
    /// (user's rule, 2026-10-04). "Show me how to X" is a task, a lavender walkthrough (user's
    /// decision, 2026-10-24: one point can't show a task of several clicks).
    public static func asksToBeShown(_ text: String) -> Bool {
        var words = ImpliedPointer.normalized(text).split(separator: " ").map(String.init)
        while let first = words.first, ["please", "can", "could", "you", "would", "will", "hey", "clickbait", "just"].contains(first) {
            words.removeFirst()
        }
        return words.starts(with: ["show", "me"]) && words.dropFirst(2).first != "how"
    }

    /// Asking outright to be walked through it: always a walkthrough, never sorted away.
    public static func insistsOnWalkthrough(_ question: String) -> Bool {
        let text = " " + ImpliedPointer.normalized(question) + " "
        return [" walk me through ", " guide me ", " teach me ", " step by step ", " tutorial "].contains { text.contains($0) }
    }

    /// The sorter's verdict: true when it's a question to answer, not something to do.
    public static func sortedAsAnswer(_ reply: String) -> Bool {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any] else { return false }
        return (object["kind"] as? String)?.lowercased() == "answer"
    }

    /// "I want to watch YouTube", "help me check Gmail": a task, unless it's about
    /// knowing something ("I want to know what this is").
    static let wishes = ["i want to", "i wanna", "i would like to", "i d like to", "help me", "take me to"]
    static let knowing: Set<String> = ["know", "understand", "learn", "see what", "find out"]

    public static func asksForTutorial(_ question: String) -> Bool {
        if asksToBeShown(question) { return false }
        let text = ImpliedPointer.normalized(question)
        if phrases.contains(where: { text.hasPrefix($0) || text.contains(" " + $0) }) { return true }
        guard let wish = wishes.first(where: { text.hasPrefix($0 + " ") }) else { return false }
        let rest = String(text.dropFirst(wish.count + 1))
        return !knowing.contains { rest.hasPrefix($0) }
    }

    /// "Where's the refresh button?", "show me the refresh button", "point at Share":
    /// finding a thing (blue, one pointer) — not doing a task (lavender). "Show me how
    /// to…" is a task and is caught by `asksForTutorial` first.
    public static func isLocatingRequest(_ text: String) -> Bool {
        if asksWhere(text) { return true }
        var words = ImpliedPointer.normalized(text).split(separator: " ").map(String.init)
        while let first = words.first, leadIns.contains(first) {
            words.removeFirst()
        }
        let joined = words.joined(separator: " ")
        if joined.hasPrefix("show me how ") { return false }  // a task: `asksForTutorial`
        let starts = ["where", "wheres", "show me", "point", "find", "highlight", "locate", "which one is", "which is"]
        return starts.contains { joined == $0 || joined.hasPrefix($0 + " ") }
    }

    /// Words people start with before the request itself ("okay, show me…", "so where's…").
    static let leadIns: Set = ["please", "can", "could", "you", "would", "will", "hey", "clickbait", "okay", "ok",
                               "so", "um", "uh", "and", "now", "right", "alright", "then", "just", "oh", "well"]

    /// Asks *where* something is — showing where (blue), never how (lavender) — anywhere in
    /// the sentence ("okay, show me where the back button is"), unless it also asks how.
    public static func asksWhere(_ text: String) -> Bool {
        let words = Set(ImpliedPointer.normalized(text).split(separator: " ").map(String.init))
        return !words.isDisjoint(with: ["where", "wheres"]) && !words.contains("how")
    }

    /// The request names a control — "where's the play button", "show me the volume
    /// slider": that's finding something on screen (blue), even when it has no text name.
    public static func namesControl(_ text: String) -> Bool {
        let words = Set(ImpliedPointer.normalized(text).split(separator: " ").map(String.init))
        return !words.isDisjoint(with: controlWords)
    }

    static let controlWords: Set = ["button", "buttons", "icon", "icons", "slider", "toggle", "switch", "field",
                                    "box", "tab", "tabs", "checkbox", "link", "menu", "knob", "arrow", "bar",
                                    "dropdown", "popup", "sidebar", "toolbar"]

    /// Orders for content, not clicks: "write me a poem", "summarise this", "explain
    /// that". They get a normal answer — never a tutorial.
    static let contentVerbs: Set<String> = ["write", "summarise", "summarize", "explain", "translate", "describe", "draft",
                                            "compose", "rewrite", "tell", "list", "define", "answer", "give", "suggest",
                                            "brainstorm", "proofread", "paraphrase", "outline", "calculate", "convert"]

    public static func isContentRequest(_ text: String) -> Bool {
        var words = ImpliedPointer.normalized(text).split(separator: " ").map(String.init)
        while let first = words.first, ["please", "can", "could", "you", "would", "will", "hey", "clickbait"].contains(first) {
            words.removeFirst()
        }
        return words.first.map(contentVerbs.contains) ?? false
    }

    /// The app a walkthrough happens in, before any planning: the app the request names,
    /// else System Settings for a Mac setting ("change my wallpaper", "turn on Night
    /// Shift"). Planning from the app in front instead walked Finder's own "Settings…".
    public static func taskApp(in text: String, apps: [String]) -> String? {
        if let named = mentionedApp(in: text, apps: apps) { return named }
        guard isSystemSetting(text) else { return nil }
        return apps.first { $0.caseInsensitiveCompare("System Settings") == .orderedSame }
    }

    /// Things only System Settings changes. Whole words or phrases, so "display" in
    /// "displayed" doesn't count; a request that names an app never gets here.
    static let systemSettingTopics = [
        "system settings", "system setting", "system preferences", "system preference", "settings app",
        "mac settings", "mac setting", "mac s settings", "macbook settings",
        "wallpaper", "desktop background", "desktop picture", "screen saver", "screensaver",
        "displays", "display settings", "external display", "second display", "screen resolution",
        "display resolution", "refresh rate", "brightness", "night shift", "true tone",
        "bluetooth", "wi fi", "wifi", "vpn", "network settings", "personal hotspot",
        "sound output", "sound input", "output device", "input device", "alert sound", "alert volume",
        "startup sound", "notifications", "notification settings", "focus mode", "focus modes", "do not disturb",
        "battery", "low power mode", "energy saver", "trackpad", "tap to click", "scroll direction",
        "tracking speed", "mouse speed", "mouse settings", "key repeat", "keyboard brightness",
        "keyboard backlight", "keyboard layout", "keyboard settings", "input source", "input sources",
        "dark mode", "light mode", "appearance", "accent color", "accent colour", "highlight color",
        "desktop and dock", "dock size", "hide the dock", "dock position", "dock magnification",
        "menu bar", "hot corners", "mission control", "stage manager", "control center", "control centre",
        "lock screen", "login items", "login password", "touch id", "apple account", "apple id", "icloud",
        "privacy settings", "location services", "screen time", "software update", "macos update",
        "update macos", "update my mac", "storage", "file sharing", "screen sharing", "family sharing",
        "printers", "add a printer", "time machine", "date and time", "date time", "time zone",
        "system language", "preferred language", "region settings", "accessibility", "voiceover",
        "cursor size", "pointer size", "siri", "apple intelligence", "firewall", "filevault",
        "default browser", "user account", "user accounts", "guest user", "startup disk",
    ]

    /// The request is only to get to `app` ("System Setting", "how do I open System
    /// Settings?"): nothing is left once the app's name and filler words are taken out.
    public static func onlyOpens(_ text: String, app: String) -> Bool {
        let filler: Set = ["how", "do", "i", "can", "you", "to", "get", "go", "open", "opening", "launch", "the", "my",
                           "show", "me", "where", "is", "s", "find", "take", "bring", "up", "access", "a", "an", "app",
                           "mac", "macs", "macbook", "please", "hey", "clickbait", "on", "this", "into", "in", "want",
                           "settings", "setting", "preferences", "preference"]
        let named = Set(ImpliedPointer.normalized(app).split(separator: " ").map(String.init))
        return ImpliedPointer.normalized(text).split(separator: " ").allSatisfy { filler.contains(String($0)) || named.contains(String($0)) }
    }

    static func isSystemSetting(_ text: String) -> Bool {
        let spoken = " " + ImpliedPointer.normalized(text) + " "
        return systemSettingTopics.contains { spoken.contains(" " + $0 + " ") }
    }

    /// An installed app the request names ("clear my Safari history" → "Safari"): the
    /// longest name found as whole words. `apps` are app names ("System Settings").
    /// The app a "where's…" request explicitly sends ClickBait to before pointing: "in Safari",
    /// "on Notes", "open Messages", "switch to Chrome" — or a Mac setting (System Settings).
    /// A plain mention is just words (user's rule, 2026-10-14): "where do I type my message to
    /// Claude" switched to the Claude app, then pointed at a caret there.
    public static func locatingApp(in text: String, apps: [String]) -> String? {
        let spoken = " " + ImpliedPointer.normalized(text) + " "
        let leads = ["in", "on", "inside", "within", "open", "launch", "switch to", "go to", "using"]
        let named = apps.filter { app in
            let name = ImpliedPointer.normalized(app)
            return name.count >= 4 && leads.contains { spoken.contains(" \($0) \(name) ") || spoken.contains(" \($0) the \(name) ") }
        }.max { $0.count < $1.count }
        if let named { return named }
        guard isSystemSetting(text) else { return nil }
        return apps.first { $0.caseInsensitiveCompare("System Settings") == .orderedSame }
    }

    public static func mentionedApp(in text: String, apps: [String]) -> String? {
        let spoken = " " + ImpliedPointer.normalized(text) + " "
        return apps
            .filter { ImpliedPointer.normalized($0).count >= 4 && spoken.contains(" " + ImpliedPointer.normalized($0) + " ") }
            .max { $0.count < $1.count }
    }
}

/// Finds a step's target among the clickable things Accessibility reports.
public enum StepMatcher {
    /// The best-named element for `target`: exact names first, then close ones; open
    /// menu items win ties (they're what the user is looking at mid-tutorial).
    public static func find(_ target: String, in elements: [ScreenElement], minimum: Double = 0.75) -> ScreenElement? {
        let scored = elements.map { element -> (ScreenElement, Double) in
            var score = LabelMatcher.similarity(target, element.label)
            if element.role == "AXMenuItem" { score += 0.01 }
            return (element, score)
        }
        return scored.filter { $0.1 >= minimum }.max { $0.1 < $1.1 }?.0
    }
}

/// The model's verdict on where the user is in a tutorial (`Prompt.progressSystem`).
public struct TutorialProgress: Equatable, Sendable {
    /// The step the user should do next, counting from 1.
    public var nextStep: Int
    public var done: Bool

    public static func parse(_ raw: String) -> TutorialProgress? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8))) as? [String: Any]
        else { return nil }
        let step = (object["next_step"] as? NSNumber)?.intValue ?? (object["next_step"] as? String).flatMap(Int.init) ?? 0
        let done = (object["done"] as? Bool) ?? false
        return TutorialProgress(nextStep: step, done: done)
    }
}

/// Trims an app's menu outline to what a question needs: every menu's title (so the
/// model knows where things live) plus the items sharing a word with the question.
/// 160 lines of Safari menus made planning slower without making it better.
public enum MenuOutline {
    /// The menu path to an item named `label` (["History", "Clear History…"]), from outline
    /// lines; nil when no item has that name. "…" and case don't matter.
    public static func path(to label: String, in lines: [String]) -> [String]? {
        let name = { (text: String) in ImpliedPointer.normalized(TutorialPlan.withoutEllipsis(text)) }
        let wanted = name(label)
        guard !wanted.isEmpty else { return nil }
        return lines.map { $0.components(separatedBy: " ▸ ") }
            .first { $0.count >= 2 && name($0[$0.count - 1]) == wanted }
    }

    public static func relevant(_ lines: [String], to question: String, limit: Int = 40) -> [String] {
        let words = Set(ImpliedPointer.normalized(question).split(separator: " ").filter { $0.count >= 4 }.map(String.init))
        var titles: [String] = []
        var matches: [String] = []
        for line in lines {
            let parts = line.components(separatedBy: " ▸ ")
            if let title = parts.first, !titles.contains(title) { titles.append(title) }
            let itemWords = Set(ImpliedPointer.normalized(parts.dropFirst().joined(separator: " ")).split(separator: " ").map(String.init))
            if !itemWords.isDisjoint(with: words) { matches.append(line) }
        }
        let shown = Set(matches.compactMap { $0.components(separatedBy: " ▸ ").first })
        return Array((matches + titles.filter { !shown.contains($0) }).prefix(limit))
    }
}

/// Whether Accessibility describes the app well enough to plan from text alone (no
/// screenshot): planning that way took ~1–2 s instead of ~10–13 s with the same steps.
public enum TutorialPlanning {
    public static func canUseTextOnly(elements: Int, menuItems: Int) -> Bool {
        elements >= 3 || menuItems >= 10
    }
}
