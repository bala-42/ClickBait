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
            if following { stopFollowing(); startFollowing() }  // edited while following: follow the new text
        }
    }
    private(set) var script = Script(text: "")

    /// The prompter under the notch is showing.
    var prompting = false
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
            voice?.resume(atLine: readingLine)
        }
    }

    func startFollowing() {
        guard voice == nil else { return }
        playing = false
        following = true
        place = nil
        let voice = VoiceFollower(readable: script.readable,
                                  onPlace: { [weak self] in self?.place = $0 },
                                  onLevel: { [weak self] new in
                                      guard let self else { return }
                                      level = level * 0.6 + new * 0.4  // smoothed, so the ring breathes
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
    var place: ScriptFollower.Place?
    @ObservationIgnored private var voice: VoiceFollower?
    /// The voice's loudness now, 0…1 (drives the ring; 0 without voice-following).
    var level: Double = 0
    var problem: String?

    private enum Key {
        static let speed = "studio.speed", fontSize = "studio.fontSize", size = "studio.size", name = "studio.name"
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
        guard panel.runBelowNotch() == .OK, let url = panel.url else { return }
        load(url)
    }

    func startPrompting() {
        guard !script.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = "add a script first"
            return
        }
        problem = nil
        prompting = true
        PrompterController.shared.show()
        startFollowing()  // it follows your voice from the start; ▶ scrolls at a set speed instead
    }

    func stopPrompting() {
        stopFollowing()
        prompting = false
        playing = false
        cuesOpen = false
        PrompterController.shared.hide()
    }

    func goTo(_ cue: Script.Cue) {
        jump = cue.start
        cuesOpen = false
        if !prompting { startPrompting() }
        let line = script.line(of: cue.start)
        place = nil
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
