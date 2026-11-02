import Foundation

/// Which orders run straight away and which ask first (the user's rules, 2026-10-20):
///
/// - **Said clearly** (`CommandParser` recognised the words, "quit Safari", "trash these"):
///   the words are the approval. Only binning files and quitting an app (unsaved work can be
///   lost) ask once.
/// - **Guessed** (the model worked out an order from other words): anything that changes
///   something asks first — opening an app, a note, a reminder, the volume, Dark Mode, a
///   folder, any file action. Only looking runs straight away: a screenshot, the media keys,
///   showing a place, a Finder window, the Desktop.
///
///     ActionPolicy.decide(.quitApp("Safari"), from: .clearOrder)   // .ask
///     ActionPolicy.decide(.openApp("Notes"), from: .clearOrder)    // .run
///     ActionPolicy.decide(.openApp("Notes"), from: .modelGuess)    // .ask
public enum ActionPolicy {
    public enum Source: String, Sendable {
        case clearOrder
        case modelGuess
    }

    public enum Verdict: Sendable {
        case run
        case ask
    }

    public static func decide(_ action: ResolvedAction, from source: Source) -> Verdict {
        switch source {
        case .clearOrder:
            switch action {
            // Every file order asks first, said clearly or not (user's ask, 2026-11-02: "a
            // confirmation pill before the work of file manipulation begins").
            case .file(.peek): .run  // only reads
            case .quitApp, .file: .ask
            default: .run
            }
        case .modelGuess:
            switch action {
            case .screenshot, .media, .openPlace, .newFinderWindow, .showDesktop, .file(.peek): .run
            default: .ask
            }
        }
    }
}
