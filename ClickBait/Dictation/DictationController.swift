import AppKit
import ClickBaitCore

/// fn+⌃ dictation (`Dictation`): hold, speak, let go — the words go into the focused field.
/// At the press: the microphone starts, the companion turns Shamrock with bars that follow the
/// voice, and the focused field and the words on screen are read (accessibility, off the main
/// thread, no screenshot). At the release: Whisper writes the words with the screen's words as
/// spelling hints, the local model tidies them for the app (raw words if it's slow), and they
/// are pasted — or only copied ("transcribed · ⌘V to paste") with no text field, in a password
/// field, or when another app came to the front meanwhile. Another key, or another modifier,
/// drops it. Nothing is logged of what was said.
@MainActor
final class DictationController {
    private let coordinator: AskCoordinator
    private let overlay: OverlayController
    private var targetTask: Task<DictationTarget, Never>?
    private var app: NSRunningApplication?
    private var work: Task<Void, Never>?
    private var recording = false

    init(coordinator: AskCoordinator, overlay: OverlayController) {
        self.coordinator = coordinator
        self.overlay = overlay
    }

    func handle(_ event: ChordDetector.Event) {
        switch event {
        case .dictatePressed: begin()
        case .dictateReleased: finish()
        case .dictateCancelled: drop(reason: "another key was pressed")
        default: break
        }
    }

    private func begin() {
        guard work == nil, !recording else { return }
        if let reason = coordinator.startDictation() {
            overlay.show(.error(reason))
            Log.ask.notice("Dictation not started: busy or no microphone")
            return
        }
        recording = true
        overlay.setDictating(true)
        let app = NSWorkspace.shared.frontmostApplication
        self.app = app
        let pid = app?.processIdentifier
        targetTask = Task.detached(priority: .userInitiated) { AXInspector.dictationTarget(pid: pid) }
        Log.ask.notice("Dictation: listening")
    }

    private func finish() {
        guard recording else { return }
        recording = false
        overlay.setDictating(true, listening: false)
        let started = ContinuousClock.now
        work = Task { [weak self] in
            await self?.write(started: started)
            self?.end()
        }
    }

    private func write(started: ContinuousClock.Instant) async {
        let target = await targetTask?.value ?? DictationTarget()
        let hints = Dictation.hints(windowTitle: target.windowTitle, labels: target.labels, textBeforeCaret: target.textBeforeCaret)
        let heard: String
        switch await coordinator.finishDictation(prompt: hints) {
        case .success(let text): heard = text
        case .failure(let error):
            overlay.setDictating(false)
            overlay.show(.error(error.message))
            return
        }
        guard !heard.isEmpty else {
            Log.ask.notice("Dictation: nothing heard")
            return
        }
        let heardAt = ContinuousClock.now
        let tidied = await coordinator.tidyDictation(heard, app: app?.localizedName, screenWords: hints)
        let text = Dictation.joined(Dictation.parseTidy(tidied, raw: heard), after: target.textBeforeCaret)
        let sameApp = app != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == app?.processIdentifier
        let delivery = Dictation.delivery(role: target.role, subrole: target.subrole, editable: target.editable, sameApp: sameApp)
        overlay.setDictating(false)
        switch delivery {
        case .paste: Clipboard.paste(text)
        case .copyOnly:
            Clipboard.copy(text)
            overlay.showDone(Dictation.copiedNote)
        }
        Log.ask.notice("""
            Dictation: \(text.count, privacy: .public) characters \(delivery == .paste ? "pasted" : "copied", privacy: .public) \
            (heard in \(String(describing: heardAt - started), privacy: .public), \
            tidied \(tidied == nil ? "no (raw)" : "yes", privacy: .public) in \(String(describing: ContinuousClock.now - heardAt), privacy: .public))
            """)
    }

    private func drop(reason: String) {
        guard recording else { return }
        recording = false
        targetTask?.cancel()
        end()
        Log.ask.notice("Dictation dropped: \(reason, privacy: .public)")
    }

    private func end() {
        coordinator.endDictation()
        if overlay.model.isDictating { overlay.setDictating(false) }
        targetTask = nil
        app = nil
        work = nil
    }
}

/// Putting dictated text in. Pasting borrows the clipboard for a moment: what was there
/// before is put back half a second later, unless something else changed it meanwhile. The
/// text is marked transient so clipboard managers skip it.
@MainActor
enum Clipboard {
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    static func paste(_ text: String) {
        let board = NSPasteboard.general
        let saved: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        board.clearContents()
        board.setString(text, forType: .string)
        board.setString("", forType: transient)
        let ours = board.changeCount
        pressCommandV()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard board.changeCount == ours else { return }
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }

    /// ⌘V to the app in front, with only ⌘ held (whatever keys are still down).
    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
