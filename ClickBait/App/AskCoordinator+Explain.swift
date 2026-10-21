import AppKit
import AVFoundation
import ClickBaitCore
import Observation

// Explaining highlighted text (⌥⌘).
extension AskCoordinator {
    // MARK: - Explain highlighted text (⌥⌘)

    func explain() {
        stopRefining()
        tutorial?.stop(message: nil)
        guard state != .listening, state != .thinking, !isAnswering else { return }
        speaker.stop()
        if let open = conversation {
            // The explanation isn't a follow-up, so the chat is let go of now — but its
            // window stays until the double-tap window passes (a second tap puts it back).
            if chatShown { detachedChat = (open, snipMemory) }
            closeChat()
            if detachedChat == nil { onChatClose?() }
        }
        errorResetTask?.cancel()

        let frontmost = NSWorkspace.shared.frontmostApplication
        guard checkCanAsk(frontmost: frontmost) else { return }
        guard AXInspector.isTrusted else {
            show(error: "Explaining highlighted text needs Accessibility. Open Permissions… from the menu bar icon.")
            return
        }

        let pid = frontmost?.processIdentifier
        frontmostPID = pid
        context = ScreenContext(appName: frontmost?.localizedName)
        let provider = settings.makeProvider()
        self.provider = provider
        Task.detached(priority: .userInitiated) { await provider.warmUp() }
        state = .thinking
        Log.ask.notice("Explain requested (frontmost: \(frontmost?.bundleIdentifier ?? "none", privacy: .private))")
        askTask = Task { await finishExplain(pid: pid) }
    }

    func finishExplain(pid: pid_t?) async {
        let startedAt = ContinuousClock.now
        let snapshot = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid) }.value
        guard !Task.isCancelled else { return }
        // The ⌘C fallback waits out a possible second tap: a double tap opens the chat and
        // needs no selection (it used to send ⌘C on the first tap).
        guard let (selected, method) = await SelectionReader.read(frontmostPID: pid, accessibilitySelection: snapshot.selectedText,
                                                                  beforeCopy: { [weak self] in
                                                                      await self?.explainCommit?.value
                                                                      return !Task.isCancelled
                                                                  })
        else {
            Log.ask.notice("Explain: no selection found (accessibility and copy both empty)")
            // Not while a second tap could still come: a double tap needs no selection.
            await explainCommit?.value
            guard !Task.isCancelled else { return }
            show(error: "Highlight text and tap ⌥⌘ — or hold ⌥⌘ and circle or drag a box around something.")
            return
        }
        guard !Task.isCancelled else { return }
        context.windowTitle = snapshot.windowTitle
        context.windowFrame = snapshot.windowFrame
        context.focusedElement = snapshot.focusedElement
        Log.ask.notice("Explain: \(selected.count, privacy: .public) characters selected via \(method.rawValue, privacy: .public)")
        if isExplainProvisional { pendingExcerpt = selected } else { onExplaining?(selected) }

        let capture: ScreenCapture
        do {
            capture = try await capturer.captureDisplayUnderCursor(excluding: settings.blocklist,
                                                                   ignoreClickBait: settings.ignoreNotchInCaptures)
        } catch {
            Log.capture.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            show(error: "Couldn't capture the screen: \(error.localizedDescription)")
            return
        }
        let encoding = Task.detached(priority: .userInitiated) { try ScreenshotEncoder.encode(capture.image) }
        let excerpt = selected.count > 120 ? selected.prefix(119) + "…" : Substring(selected)
        // Explanations are read, not heard: you didn't use your voice.
        await respond(question: "", selectedText: selected, capture: capture, encoding: encoding, startedAt: startedAt,
                      speak: false, display: "Explain: “\(excerpt)”")
    }

    /// The microphone's level while listening, for the waveform.
    var microphoneLevel: Float { state == .listening || isDictating ? recorder.level : 0 }
}
