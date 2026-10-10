import Foundation
import Observation

/// The 🔒/🌐 switch: off at every launch, switched on only by the user from the menu bar,
/// never saved anywhere. With it on, a question goes online only when its words ask
/// (`WebLookup.reason`), and a snip looks up its subject (spec decisions 3 and 6).
@MainActor
@Observable
final class InternetMode {
    static let maxRecent = 5

    private(set) var isOn = false
    /// The last few search phrases and addresses sent, newest first. Memory only.
    private(set) var recent: [String] = []

    @ObservationIgnored var onChange: (() -> Void)?

    func toggle() {
        isOn.toggle()
        if !isOn { recent.removeAll() }
        Log.app.notice("Internet Mode \(self.isOn ? "on 🌐" : "off 🔒", privacy: .public)")
        onChange?()
    }

    func record(_ lookup: String) {
        let text = lookup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recent.removeAll { $0 == text }
        recent.insert(text, at: 0)
        if recent.count > Self.maxRecent { recent.removeLast(recent.count - Self.maxRecent) }
        onChange?()
    }
}
