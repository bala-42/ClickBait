import AppKit

/// Settings → Privacy → Uninstall (idea from Sentient OS's teardown): after a confirmation,
/// removes everything ClickBait keeps on this Mac and resets only its own permissions, then
/// quits. Ollama, its models and a SearXNG container stay (they aren't ClickBait's); the app
/// itself goes to the Trash by hand, so a copy being built or tested is never deleted.
@MainActor
enum Uninstaller {
    /// ClickBait's own folder: NOTES.md, the notes folder, saved answers, Vision Memory's index and your face
    /// reference, the speech model, SearXNG settings.
    static var supportFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "ClickBait", directoryHint: .isDirectory)
    }

    static func confirmAndRun() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Uninstall ClickBait?"
        alert.informativeText = """
            This deletes everything ClickBait keeps on this Mac: remembered facts, your notes folder, saved answers, \
            Vision Memory (what it read and described in your pictures and videos, and your face reference), \
            the speech model, SearXNG settings, debug captures and all of its settings. It also \
            resets ClickBait's Microphone, Camera, Screen Recording and Accessibility permissions. \
            Ollama and its models stay.

            ClickBait then quits. Drag it to the Trash to finish.
            """
        alert.addButton(withTitle: "Uninstall").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run()
    }

    private static func run() {
        AgentHookInstaller.remove()  // Claude Code's settings without ClickBait's hooks
        let bundleID = Bundle.main.bundleIdentifier ?? "org.clickbait.ClickBait"
        // Only ClickBait's own entries: `tccutil reset All <bundle id>`.
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "All", bundleID]
        var resetStatus: Int32 = -1
        do {
            try reset.run()
            reset.waitUntilExit()
            resetStatus = reset.terminationStatus
        } catch {
            Log.app.error("Uninstall: tccutil failed: \(error.localizedDescription, privacy: .public)")
        }
        if let supportFolder { try? FileManager.default.removeItem(at: supportFolder) }
        DebugCaptureStore.deleteAll()
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        Log.app.notice("Uninstall: files, settings and permissions removed (tccutil exit \(resetStatus, privacy: .public))")
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])  // where to drag it from
        NSApp.terminate(nil)
    }
}
