import AppKit
import ClickBaitCore
import Observation
import OSLog
import PDFKit
import UniformTypeIdentifiers

/// Studio (user's ask, 2026-11-01; the notch's Mirror grown up): the camera for quick checks
/// and photos, and a teleprompter that hangs from the notch, right under the camera, so
/// reading a script looks like eye contact. The script and its settings stay on this Mac
/// (`~/Library/Application Support/ClickBait/Studio/`).
@MainActor @Observable
final class StudioModel {
    static let shared = StudioModel()

    enum Mode: String { case mirror, prompter }
    var mode: Mode = .mirror

    var name = "Untitled script"
    var text = "" {
        didSet {
            script = Script(text: text)
            scheduleSave()
            // Edited while following: follow the new text (only a real change: the editor
            // writes the same text back as the notch folds, and that restarted it mid-speech).
            if following, text != oldValue {
                Log.app.notice("Studio: script edited while following: restarting")
                stopFollowing()
                startFollowing()
            }
        }
    }
    private(set) var script = Script(text: "")

    /// The prompter under the notch is showing.
    var prompting = false
    /// The morph: false while it grows out of the notch (and shrinks back into it).
    var shown = false
    /// Set by the notch: folds it (floating: the prompter is its own window).
    @ObservationIgnored var foldNotch: (() -> Void)?
    /// Set by the notch: the prompter started, stopped or changed size in it.
    @ObservationIgnored var notchChanged: (() -> Void)?
    /// Prompting in the notch itself (not floating): the open notch is the prompter.
    var inNotch: Bool { prompting && !floating }
    /// Scrolling by itself (phase 1: at `speed`; with voice-following, at your pace).
    var playing = false
    /// Points a second.
    var speed: Double = 28 { didSet { UserDefaults.standard.set(speed, forKey: Key.speed) } }
    var fontSize: Double = 22 { didSet { UserDefaults.standard.set(fontSize, forKey: Key.fontSize) } }
    var size = CGSize(width: 520, height: 170) {
        didSet { UserDefaults.standard.set([size.width, size.height], forKey: Key.size) }
    }
    /// How far the text has scrolled, in points; at most `maxOffset` (set by the prompter).
    var offset: Double = 0
    @ObservationIgnored var maxOffset: Double = 0

    func scroll(by points: Double) {
        offset = min(max(0, offset + points), maxOffset)
        // Scrolled by hand while following: reading picks up from what's now at the top.
        if following {
            place = nil
            lastMatch = nil
            reading = Double(follower?.words.firstIndex { $0.line >= readingLine } ?? 0)
            voice?.resume(atLine: readingLine)
        }
    }

    func startFollowing() {
        guard voice == nil else { return }
        playing = false
        following = true
        place = nil
        lastMatch = nil
        follower = ScriptFollower(readable: script.readable)
        reading = Double(follower?.words.firstIndex { $0.line >= readingLine } ?? 0)
        let voice = VoiceFollower(readable: script.readable,
                                  onPlace: { [weak self] in self?.place = $0 },
                                  onLevel: { [weak self] new in
                                      guard let self else { return }
                                      if new > 0.25 { spokeAt = Date() }  // (already above the room)
                                      // Soft, like Moody's: it eases up with the voice and settles
                                      // slowly (it jumped with every syllable: "not soft").
                                      level = new > level ? level * 0.82 + new * 0.18 : level * 0.94 + new * 0.06
                                  },
                                  onProblem: { [weak self] message in
                                      self?.problem = message
                                      self?.stopFollowing()
                                  })
        self.voice = voice
        voice.resume(atLine: readingLine)
        Task { await voice.start() }
    }

    func stopFollowing() {
        voice?.stop()
        voice = nil
        following = false
        place = nil
        level = 0
    }
    /// A cue was picked: the prompter scrolls to it (its character offset).
    var jump: Int?
    /// The cue list hangs open under the prompter.
    var cuesOpen = false {
        didSet { if cuesOpen != oldValue { PrompterController.shared.resize(to: size) } }
    }
    /// The prompter line at the top of what's showing, for marking the current cue.
    var readingLine = 0
    /// Following the voice (phase 2): the prompter runs at your pace, still when you stop.
    var following = false
    /// Where the voice is in the script (the last confident match).
    var place: ScriptFollower.Place? {
        didSet { if let place { learnPace(from: place) } }
    }
    /// Pace (user's ask: "it is not pace-reactive yet"): matches land about once a second, a
    /// second late, so between them the prompter runs on at your reading speed while you speak
    /// and stops as you go quiet. `reading` is that running word position; `pace` words a
    /// second, learnt from the matches; `spokeAt` the last moment the voice was loud.
    @ObservationIgnored var reading: Double = 0
    @ObservationIgnored var pace: Double = 2.5
    @ObservationIgnored var spokeAt = Date.distantPast
    @ObservationIgnored private var lastMatch: (word: Int, at: Date)?
    @ObservationIgnored var follower: ScriptFollower?
    var speaking: Bool { Date().timeIntervalSince(spokeAt) < 0.35 }

    private func learnPace(from place: ScriptFollower.Place) {
        let now = Date()
        if let last = lastMatch, place.word > last.word {
            let seconds = now.timeIntervalSince(last.at)
            if seconds > 0.3, seconds < 6 {
                pace = min(5, max(0.8, pace * 0.7 + Double(place.word - last.word) / seconds * 0.3))
            }
        }
        lastMatch = (place.word, now)
        Log.app.debug("Studio: at word \(place.word, privacy: .public) (line \(place.line, privacy: .public)), pace \(String(format: "%.1f", self.pace), privacy: .public) words/s")
        // Behind the match: catch up; ran a little ahead: keep going (it was right); far ahead: back.
        if Double(place.word) > reading || reading - Double(place.word) > 4 { reading = Double(place.word) }
    }
    @ObservationIgnored private var voice: VoiceFollower?
    /// The voice's loudness now, 0…1 (drives the ring; 0 without voice-following).
    var level: Double = 0
    var problem: String?
    /// The brain is rewriting the script (`ScriptRewrite`); the text before, for Undo.
    var rewriting: ScriptRewrite.Job?
    var undoText: String?
    /// Set by the app delegate: the local brain's model name.
    @ObservationIgnored static var brain: (() -> String)?

    /// Floating (user's ask, 2026-11-01): away from the notch, anywhere on screen, for an
    /// external display or a camera elsewhere; where its top centre was left.
    var floating = false {
        didSet {
            UserDefaults.standard.set(floating, forKey: Key.floating)
            guard floating != oldValue, prompting else { return }
            // Out of the notch into its own window, or back into the notch.
            if floating {
                shown = true
                PrompterController.shared.show()
            } else {
                PrompterController.shared.hide()
            }
            notchChanged?()
        }
    }
    var floatAt: CGPoint? {
        didSet { if let floatAt { UserDefaults.standard.set([floatAt.x, floatAt.y], forKey: Key.floatAt) } }
    }
    /// Following was paused (⌃⌘P or the pause button), to resume it.
    @ObservationIgnored private var pausedFollowing = false

    private enum Key {
        static let speed = "studio.speed", fontSize = "studio.fontSize", size = "studio.size", name = "studio.name"
        static let floating = "studio.floating", floatAt = "studio.floatAt"
    }

    private static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "ClickBait/Studio", directoryHint: .isDirectory)
    private static var scriptFile: URL { folder.appending(path: "script.txt") }
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        speed = defaults.object(forKey: Key.speed) as? Double ?? 28
        fontSize = defaults.object(forKey: Key.fontSize) as? Double ?? 22
        if let saved = defaults.array(forKey: Key.size) as? [Double], saved.count == 2 { size = CGSize(width: saved[0], height: saved[1]) }
        name = defaults.string(forKey: Key.name) ?? name
        floating = defaults.bool(forKey: Key.floating)
        if let at = defaults.array(forKey: Key.floatAt) as? [Double], at.count == 2 { floatAt = CGPoint(x: at[0], y: at[1]) }
        text = (try? String(contentsOf: Self.scriptFile, encoding: .utf8)) ?? ""
    }

    /// The file types a script can come from.
    static let fileTypes: [UTType] = [.plainText, .text, .rtf, .rtfd, .html, .pdf, UTType("net.daringfireball.markdown") ?? .text,
                                      UTType("org.openxmlformats.wordprocessingml.document") ?? .data]

    /// Reads a script from a file: text and Markdown as they are; RTF, Word and web pages
    /// through the system's text reader; PDFs through PDFKit.
    func load(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        var read: String?
        if ext == "pdf" {
            read = PDFDocument(url: url)?.string
        } else if ["txt", "md", "markdown", "text", ""].contains(ext) {
            read = try? String(contentsOf: url, encoding: .utf8)
        } else {
            read = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        guard let read, !read.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = "couldn't read a script from \(url.lastPathComponent)"
            return
        }
        problem = nil
        name = url.deletingPathExtension().lastPathComponent
        UserDefaults.standard.set(name, forKey: Key.name)
        text = read.replacingOccurrences(of: "\r\n", with: "\n")
        offset = 0
        Log.app.notice("Studio: script loaded (\(self.script.cues.count, privacy: .public) cues)")
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.fileTypes
        panel.message = "Choose a script: text, Markdown, Word, RTF, a web page or a PDF."
        panel.openFromNotch { [weak self] urls in
            if let url = urls.first { self?.load(url) }
        }
    }

    func startPrompting() {
        guard !script.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = "add a script first"
            return
        }
        problem = nil
        prompting = true
        if floating {
            // Its own window, growing out of the folding notch.
            foldNotch?()
            shown = false
            PrompterController.shared.show()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                shown = true
            }
        } else {
            // The open notch itself springs into the prompter (user's ask, 2026-11-01: "the
            // thing does not turn into the prompter … a separate notch situation").
            shown = true
            notchChanged?()
        }
        startFollowing()  // it follows your voice from the start; ▶ scrolls at a set speed instead
    }

    func stopPrompting() {
        stopFollowing()
        playing = false
        cuesOpen = false
        if !floating {
            // The notch springs back to Studio.
            prompting = false
            shown = false
            notchChanged?()
            return
        }
        shown = false  // shrinks back into the notch, then goes
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard !shown else { return }
            prompting = false
            PrompterController.shared.hide()
        }
    }

    // MARK: Shortcuts (while prompting): ⌃⌘P, ⌃⌘↑ ↓, ⌃⌘← →

    /// Pause, or carry on: following the voice stops and resumes; a set-speed scroll pauses and plays.
    func togglePause() {
        if following {
            stopFollowing()
            pausedFollowing = true
        } else if playing {
            playing = false
        } else if pausedFollowing {
            pausedFollowing = false
            startFollowing()
        } else {
            startFollowing()
        }
    }

    func nextCue(_ step: Int) {
        let cues = script.cues
        guard !cues.isEmpty else { return }
        let current = script.cue(atLine: readingLine).flatMap { cue in cues.firstIndex(of: cue) } ?? 0
        goTo(cues[min(max(0, current + step), cues.count - 1)])
    }

    func changeSpeed(_ step: Double) {
        speed = min(120, max(6, speed + step))
        if following { pace = min(5, max(0.8, pace * (step > 0 ? 1.15 : 0.87))) }
    }

    // MARK: The brain's rewrite

    /// Make it speakable (and create the cues), or only create the cues; the old text kept for Undo.
    func rewrite(_ job: ScriptRewrite.Job) {
        let original = text
        guard rewriting == nil, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let brain = Self.brain?() else {
            problem = "add a script first"
            return
        }
        rewriting = job
        problem = nil
        if job == .cuesOnly {
            organize(original, brain: brain)
            return
        }
        Task { @MainActor in
            defer { rewriting = nil }
            let words = ScriptFollower.normalized(original).count
            var call = URLRequest(url: OllamaProvider.baseURL.appending(path: "api/generate"), timeoutInterval: 240)
            call.httpMethod = "POST"
            call.setValue("application/json", forHTTPHeaderField: "Content-Type")
            call.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": brain, "prompt": ScriptRewrite.prompt(job, script: original), "stream": false, "think": false,
                "options": ["temperature": job == .cuesOnly ? 0 : 0.4, "num_predict": words * 3 + 200]
            ] as [String: Any])
            guard let (data, response) = try? await URLSession.shared.data(for: call),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reply = json["response"] as? String else {
                problem = "the brain didn't answer: is Ollama running?"
                return
            }
            let rewritten = ScriptRewrite.cleaned(reply)
            switch job {
            case .cuesOnly where !ScriptRewrite.keepsWords(original: original, rewritten: rewritten):
                problem = "the brain changed your words, so your script is kept as it was"
                return
            case .speakable where !ScriptRewrite.plausible(original: original, rewritten: rewritten):
                problem = "the rewrite came back too short, long or without cues: try again"
                return
            default: break
            }
            guard text == original else { return }  // edited meanwhile: theirs wins
            undoText = original
            text = rewritten
            offset = 0
            Log.app.notice("Studio: \(job == .speakable ? "made speakable" : "cues added", privacy: .public) (\(self.script.cues.count, privacy: .public) cues)")
        }
    }

    /// Add cues: your sentences sorted into sections by topic, each named — the brain only
    /// groups them (a structured answer); the script is rebuilt from the exact sentences.
    private func organize(_ original: String, brain: String) {
        let sentences = ScriptOrganizer.sentences(of: original)
        guard sentences.count >= 2 else { problem = "the script needs a few sentences to sort"; rewriting = nil; return }
        Task { @MainActor in
            defer { rewriting = nil }
            var call = URLRequest(url: OllamaProvider.baseURL.appending(path: "api/generate"), timeoutInterval: 240)
            call.httpMethod = "POST"
            call.setValue("application/json", forHTTPHeaderField: "Content-Type")
            call.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": brain, "prompt": ScriptOrganizer.prompt(sentences), "stream": false, "think": false,
                "format": ScriptOrganizer.schema, "options": ["temperature": 0]
            ] as [String: Any])
            struct Answer: Decodable { let sections: [ScriptOrganizer.Section] }
            guard let (data, response) = try? await URLSession.shared.data(for: call),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reply = (json["response"] as? String)?.data(using: .utf8),
                  let answer = try? JSONDecoder().decode(Answer.self, from: reply),
                  let organized = ScriptOrganizer.assemble(sentences, sections: answer.sections) else {
                problem = "the brain couldn't sort it: is Ollama running?"
                return
            }
            guard text == original else { return }  // edited meanwhile: theirs wins
            undoText = original
            text = organized
            offset = 0
            Log.app.notice("Studio: organized into \(self.script.cues.count, privacy: .public) cues")
        }
    }

    func undoRewrite() {
        guard let undoText else { return }
        text = undoText
        self.undoText = nil
    }

    func goTo(_ cue: Script.Cue) {
        jump = cue.start
        // The cue list stays open: it closes only from its own button (user's ask, 2026-11-01).
        if !prompting { startPrompting() }
        let line = script.line(of: cue.start)
        place = nil
        lastMatch = nil
        reading = Double(follower?.words.firstIndex { $0.line >= line } ?? 0)
        voice?.resume(atLine: line)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let text = text
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try? text.write(to: Self.scriptFile, atomically: true, encoding: .utf8)
        }
    }
}
