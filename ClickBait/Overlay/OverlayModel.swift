import ClickBaitCore
import Foundation
import Observation

/// What the overlay windows draw. Owned by `OverlayController`, observed by the views.
@MainActor
@Observable
final class OverlayModel {
    enum Bubble: Equatable {
        case idle
        case listening
        case thinking(heard: String?)
        /// ⌥⌘: explaining highlighted text (shows its start).
        case explaining(excerpt: String)
        case answer(String)
        case error(String)
    }

    var bubble: Bubble = .idle
    /// Pointers being shown, in global AppKit points. Empty when nothing is pointed at.
    var pointers: [ScreenPointer] = []
    /// Changes every time a new set of pointers appears, to restart their animation.
    var pointerGeneration = 0
}
