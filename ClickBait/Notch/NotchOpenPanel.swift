import AppKit

/// A file picker opened from the notch (Studio's "Open a script…", Settings' folder, photo and
/// speech-model choosers): a sheet dropping from the open notch itself, dark like ClickBait, on
/// the desktop you're on. Run on its own it made ClickBait the active app, and macOS took the
/// user to another desktop to show it (user's report, 2026-11-01: "it just goes to desktop").
extension NSOpenPanel {
    /// `done` gets the chosen files, or none when cancelled.
    @MainActor
    func openFromNotch(_ done: @escaping @MainActor ([URL]) -> Void) {
        appearance = NSAppearance(named: .darkAqua)
        guard let notch = NSApp.windows.first(where: { $0 !== self && $0.isVisible && $0.level == WindowLayers.notch && $0.frame.height > 60 }) else {
            // No open notch (shouldn't happen): a picker on this desktop, above everything.
            level = WindowLayers.dock
            collectionBehavior.insert(.moveToActiveSpace)
            let response = runModal()
            done(response == .OK ? urls : [])
            return
        }
        // The notch takes the keyboard (it doesn't by itself) so the sheet can be typed in.
        notch.makeKey()
        beginSheetModal(for: notch) { [weak self] response in
            let chosen = response == .OK ? (self?.urls ?? []) : []
            MainActor.assumeIsolated { done(chosen) }
        }
    }
}
