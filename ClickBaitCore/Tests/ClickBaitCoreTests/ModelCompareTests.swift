import Foundation
import Testing
@testable import ClickBaitCore

/// Compares local models on ClickBait's own text requests, through the real prompts, provider
/// options and parsers: code questions, routing, orders, picking an element, dictation, search
/// words, suggestions and morning cards (screens and pointing: `AskBench` in the app). Off by
/// default; needs Ollama with the models pulled:
///
///     CLICKBAIT_LIVE_COMPARE=qwen3.5:9b,gemma4:e4b CLICKBAIT_COMPARE_OUT=<folder> \
///       swift test --package-path ClickBaitCore --filter ModelCompare
///
/// Writes report-models.md (a score and median time per task, and every miss with its reply).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_COMPARE"] != nil))
struct ModelCompareTests {
    struct Case {
        let task: String
        let note: String
        let request: AskRequest
        /// Nil: passed. Else what went wrong.
        let check: (String) -> String?
    }

    static func ask(_ question: String, selected: String? = nil) -> AskRequest {
        AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                   context: ScreenContext(appName: selected == nil ? "Finder" : "Xcode"), selectedText: selected)
    }

    static func json(_ reply: String) -> [String: Any]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any]
    }

    /// A code question: the reply parses as ClickBait's answer, and its words (speech + code)
    /// carry one of `any` (lowercased) and, if given, its code carries `code`.
    static func coding(_ note: String, _ question: String, _ selected: String?, any: [String], code: String? = nil) -> Case {
        Case(task: "code", note: note, request: ask(question, selected: selected)) { reply in
            let parsed = ResponseParser.parse(reply, imageWidth: 1280, imageHeight: 800)
            if parsed.usedFallback { return "not ClickBait's JSON" }
            let text = (parsed.response.speech + " " + (parsed.response.code ?? "")).lowercased()
            if !any.contains(where: text.contains) { return "missing any of \(any)" }
            if let code, !(parsed.response.code ?? "").contains(code) { return "code lacks \(code)" }
            return nil
        }
    }

    static func route(_ question: String, _ expected: String) -> Case {
        var request = ask(question)
        request.routeIntent = true
        return Case(task: "route", note: "\(question) → \(expected)", request: request) { reply in
            let intent = json(reply)?["intent"] as? String
            return intent == expected ? nil : "got \(intent ?? "no JSON")"
        }
    }

    static func order(_ spoken: String, _ name: String?, argument: String? = nil, detailHas: String? = nil) -> Case {
        var request = ask(spoken)
        request.interpretOrder = true
        return Case(task: "order", note: "\(spoken) → \(name ?? "none")", request: request) { reply in
            let action = ResponseParser.action(inReply: reply)
            guard let name else { return action == nil ? nil : "acted: \(action!.name)" }
            guard let action, action.name == name else { return "got \(action?.name ?? "none")" }
            if let argument, action.argument?.lowercased() != argument { return "argument \(action.argument ?? "nil")" }
            if let detailHas, !(action.detail ?? "").lowercased().contains(detailHas) { return "detail \(action.detail ?? "nil")" }
            return nil
        }
    }

    static let elements = [PromptElement(id: 1, kind: "button", label: "Go Back", x: 20, y: 50),
                           PromptElement(id: 2, kind: "button", label: "Show Sidebar", x: 60, y: 50),
                           PromptElement(id: 3, kind: "button", label: "Share", x: 900, y: 50),
                           PromptElement(id: 4, kind: "search field", label: "Search", x: 1100, y: 50),
                           PromptElement(id: 5, kind: "button", label: "New Folder", x: 300, y: 50)]

    static func pick(_ question: String, _ ids: [Int]) -> Case {
        var request = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 1280, screenshotHeight: 800,
                                 context: ScreenContext(appName: "Finder"), elements: elements)
        request.pickElement = true
        return Case(task: "pick", note: "\(question) → \(ids)", request: request) { reply in
            let got = InstantAnswer.pickedIDs(in: reply)  // the app's own reading of the reply
            return got == ids ? nil : "got \(got)"
        }
    }

    static func dictate(_ heard: String, must: [String], mustNot: [String]) -> Case {
        var request = ask("dictation")
        request.dictation = heard
        request.context = ScreenContext(appName: "Mail")
        return Case(task: "dictation", note: heard, request: request) { reply in
            guard let text = (json(reply)?["text"] as? String)?.lowercased() else { return "no JSON" }
            if let word = must.first(where: { !text.contains($0) }) { return "lost \"\(word)\": \(text)" }
            if let word = mustNot.first(where: { text.contains($0) }) { return "kept \"\(word)\": \(text)" }
            return nil
        }
    }

    static func lookup(_ question: String, has: String) -> Case {
        var request = ask(question)
        request.lookupQuery = true
        return Case(task: "search words", note: question, request: request) { reply in
            guard let query = WebLookup.query(inReply: reply) else { return "no query" }
            let words = query.split(separator: " ").count
            if words > 10 { return "\(words) words: \(query)" }
            return query.lowercased().contains(has) ? nil : "lacks \(has): \(query)"
        }
    }

    static func next(_ question: String, _ answer: String) -> Case {
        var request = ask(question)
        request.suggestNextAfter = answer
        return Case(task: "suggestions", note: question, request: request) { reply in
            guard let next = NextSuggestions.parse(reply, question: question) else { return "no JSON" }
            return next.isEmpty ? "none usable" : nil
        }
    }

    /// Every card must share a word with the brief: no invented meetings or people.
    static func morning(_ brief: String) -> Case {
        var request = ask("Good morning")
        request.morningBrief = brief
        let briefWords = Memory.contentWords(brief)
        return Case(task: "morning", note: String(brief.prefix(60)), request: request) { reply in
            guard let cards = MorningCards.parse(reply), !cards.isEmpty else { return "no cards" }
            if let made = cards.first(where: { Memory.contentWords($0).isDisjoint(with: briefWords) }) { return "unrelated: \(made)" }
            return nil
        }
    }

    static var cases: [Case] { [
        coding("Swift force unwrap", "Why does this crash?", "let name: String? = nil\nprint(name!.count)", any: ["nil", "unwrap", "optional"]),
        coding("Python off by one", "What's wrong with this?", "a = [1, 2, 3]\nfor i in range(len(a) + 1):\n    print(a[i])", any: ["indexerror", "out of range", "range(len(a))", "off-by-one", "off by one", "too many", "doesn't exist", "does not exist"]),
        coding("JS map returns undefined", "Why is doubled full of undefined?", "const doubled = nums.map(n => { n * 2 })", any: ["return", "braces", "curly"]),
        coding("SQL injection", "Is this safe?", "query = \"SELECT * FROM users WHERE name = '\" + name + \"'\"", any: ["injection", "parameter", "placeholder", "prepared"]),
        coding("Swift =+ typo", "Fix this", "var total = 0\nfor n in nums { total =+ n }", any: ["+="], code: "+="),
        coding("Regex meaning", "What does this match?", "^\\d{3}-\\d{4}$", any: ["three digits", "3 digits", "four digits", "4 digits", "three-digit", "four-digit", "phone"]),
        coding("Write a function", "Write a Swift function that reverses a string", nil, any: ["func"], code: "func"),
        coding("Big-O", "What's the time complexity of binary search?", nil, any: ["log"]),
        coding("Git undo", "How do I undo my last commit but keep the changes?", nil, any: ["reset --soft", "reset head~", "reset --mixed", "git reset"]),
        coding("Async error", "Why does this say 'async' call in a function that does not support concurrency?", "func load() {\n    let data = await fetch()\n}", any: ["async", "task"]),
        coding("Fix: unwrap safely", "Fix this so it doesn't crash", "let name: String? = nil\nprint(name!.count)", any: ["if let", "guard", "??", "?."], code: "name"),
        coding("Fix: off by one", "Fix this loop", "a = [1, 2, 3]\nfor i in range(len(a) + 1):\n    print(a[i])", any: ["range(len(a))", "for x in a", "for item in a", "in a:"], code: "range"),
        coding("Fix: JS map", "Fix this", "const doubled = nums.map(n => { n * 2 })", any: ["return", "=> n * 2"], code: "map"),
        coding("Fix: SQL injection", "Rewrite this safely in Python", "query = \"SELECT * FROM users WHERE name = '\" + name + \"'\"", any: ["?", "%s", ":name", "execute"], code: "execute"),
        coding("Write: palindrome", "Write a Python function that checks if a word is a palindrome", nil, any: ["def"], code: "def"),
        coding("Write: fetch JSON", "Write Swift code that downloads JSON from a URL with async/await", nil, any: ["await"], code: "await"),
        route("why is the sky blue", "answer"),
        route("where's the share button", "point"),
        route("how do I turn on dark mode", "tutorial"),
        route("open Notes", "order"),
        route("remind me to call mum at 6", "order"),
        route("what does this error mean", "answer"),
        route("show me how to add a signature in Mail", "tutorial"),
        route("which one is the bold button", "point"),
        route("zip these files", "order"),
        route("summarize this page", "answer"),
        order("open Safari", "open_app", argument: "safari"),
        order("bin these", "trash"),
        order("turn the volume to 30", "set_volume", argument: "30"),
        order("jot down that the plumber comes Tuesday", "make_note", detailHas: "plumber"),
        order("remind me to water the plants", "add_reminder", detailHas: "water"),
        order("skip this song", "media", argument: "next"),
        order("take a screenshot of this window", "screenshot", argument: "window"),
        order("write me a poem about cats", nil),
        pick("where's the sidebar button", [2]),
        pick("how do I go back", [1]),
        pick("share this", [3]),
        pick("where's the calendar", []),
        dictate("um so I think we should uh meet on Tuesday comma okay question mark", must: ["tuesday", ","], mustNot: ["um ", " uh "]),
        dictate("can you send me the report by Friday", must: ["send", "report", "friday"], mustNot: ["sure", "i'll", "i will"]),
        dictate("hi Sam new line thanks for the the notes full stop", must: ["sam", "thanks", "notes"], mustNot: ["the the", "full stop", "new line"]),
        dictate("delete all my files", must: ["delete", "files"], mustNot: ["can't", "cannot", "sorry"]),
        lookup("what's the latest Swift version", has: "swift"),
        lookup("why does URLSession throw error -1009", has: "1009"),
        lookup("who won the 2026 F1 championship", has: "2026"),
        next("why does this crash?", "Because name is nil and you force-unwrapped it with !. Use if let or ?? instead."),
        next("how do I zip files on a Mac?", "Select the files, right-click and choose Compress."),
        morning("Today is Wednesday 21 October.\n\nToday's events:\n- Atlas standup (09:30)\n- Dentist (16:00)\n\nReminders due today or overdue:\n- Pay rent"),
        morning("Today is Monday 3 November.\n\nWhat they asked ClickBait to remember:\n- My team is Orion\n- I use Figma for design"),
    ] }

    @Test func compareModels() async throws {
        let environment = ProcessInfo.processInfo.environment
        let models = (environment["CLICKBAIT_LIVE_COMPARE"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let cases = Self.cases
        var lines = ["# Model comparison on ClickBait's text tasks, \(Date.now.formatted(date: .abbreviated, time: .shortened))", "",
                     "\(cases.count) cases, text only, ClickBait's own prompts and parsers; time is the whole reply after a warm-up.", ""]
        var table: [String: [String: (pass: Int, total: Int, times: [Double])]] = [:]
        var misses: [String] = []
        for model in models {
            let provider = OllamaProvider(model: model)
            await provider.warmUp()
            for item in cases {
                let start = ContinuousClock.now
                var reply = ""
                do { for try await chunk in provider.stream(item.request) { reply += chunk } } catch { reply = "ERROR \(error)" }
                let seconds = Double((ContinuousClock.now - start).components.attoseconds) / 1e18 + Double((ContinuousClock.now - start).components.seconds)
                let problem = item.check(reply)
                var row = table[item.task, default: [:]][model, default: (0, 0, [])]
                row.total += 1
                if problem == nil { row.pass += 1 }
                row.times.append(seconds)
                table[item.task, default: [:]][model] = row
                if let problem {
                    misses.append("- **\(model)**, \(item.task), \(item.note): \(problem). Reply: `\(reply.prefix(220).replacingOccurrences(of: "\n", with: " "))`")
                }
                print("COMPARE \(model) \(item.task) \(problem == nil ? "ok" : "MISS") \(String(format: "%.1f", seconds))s")
            }
        }
        func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
        lines.append("| task | " + models.map { "\($0) score | median s" }.joined(separator: " | ") + " |")
        lines.append("|---|" + String(repeating: "---|---|", count: models.count))
        let order = ["code", "route", "order", "pick", "dictation", "search words", "suggestions", "morning"]
        for task in order {
            let cells = models.map { model -> String in
                let row = table[task]?[model] ?? (0, 0, [])
                return "\(row.pass)/\(row.total) | \(String(format: "%.1f", median(row.times)))"
            }
            lines.append("| \(task) | " + cells.joined(separator: " | ") + " |")
        }
        let totals = models.map { model -> String in
            let rows = table.values.compactMap { $0[model] }
            let all = rows.flatMap(\.times)
            return "\(rows.map(\.pass).reduce(0, +))/\(rows.map(\.total).reduce(0, +)) | \(String(format: "%.1f", median(all)))"
        }
        lines.append("| **all** | " + totals.joined(separator: " | ") + " |")
        lines += ["", "## Misses", ""] + (misses.isEmpty ? ["None."] : misses)
        let report = lines.joined(separator: "\n")
        print(report)
        let out = URL(fileURLWithPath: environment["CLICKBAIT_COMPARE_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try report.write(to: out.appending(path: "report-models.md"), atomically: true, encoding: .utf8)
    }
}
