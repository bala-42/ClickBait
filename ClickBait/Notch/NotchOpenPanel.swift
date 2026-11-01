import AppKit

/// A file picker opened from the notch (Studio's "Open a script…", Settings' folder and photo
/// choosers): dark like ClickBait, above the notch panel, and just below it on its screen
/// (user's report, 2026-11-01: it opened light, behind the notch).
extension NSOpenPanel {
    @MainActor
    func runBelowNotch() -> NSApplication.ModalResponse {
        appearance = NSAppearance(named: .darkAqua)
        level = WindowLayers.dock
        NSApp.activate()
        placeBelowNotch()
        // The panel places itself as it opens: placed again once it's up (the main queue
        // still runs while it's modal).
        nonisolated(unsafe) let panel = self
        DispatchQueue.main.async { MainActor.assumeIsolated { panel.placeBelowNotch() } }
        return runModal()
    }

    @MainActor
    private func placeBelowNotch() {
        guard let notch = NSApp.windows.first(where: { $0 !== self && $0.isVisible && $0.level == WindowLayers.notch && $0.frame.height > 60 }),
              let screen = notch.screen else { return }
        let top = min(notch.frame.minY - 10, screen.visibleFrame.maxY)
        setFrameOrigin(NSPoint(x: screen.frame.midX - frame.width / 2, y: max(screen.visibleFrame.minY, top - frame.height)))
    }
}
