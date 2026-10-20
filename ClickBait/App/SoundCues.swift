import AppKit

/// Two soft macOS system sounds (C6, 2026-10-20; never HeyClicky's files): one when a
/// background job is done, one when ClickBait needs a yes. Off in the menu (Sounds). Quiet,
/// and never more than one a second.
@MainActor
enum SoundCues {
    enum Cue: String {
        case done = "Glass"
        case needsYou = "Pop"
    }

    private static var lastPlayed = Date.distantPast

    static func play(_ cue: Cue, enabled: Bool) {
        guard enabled, Date().timeIntervalSince(lastPlayed) > 1, let sound = NSSound(named: cue.rawValue) else { return }
        lastPlayed = Date()
        sound.volume = 0.35
        sound.play()
    }
}
