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
        /// A spoken command was carried out.
        case done(String)
        case error(String)
    }

    var bubble: Bubble = .idle
    /// Pointers being shown, in global AppKit points. Empty when nothing is pointed at.
    var pointers: [ScreenPointer] = []
    /// The companion's drawn size. Ignored by observation: the controller reacts through
    /// `onBubbleSizeChange` instead, and the view never reads it.
    @ObservationIgnored var bubbleSize: CGSize = .zero {
        didSet { if bubbleSize != oldValue { onBubbleSizeChange?() } }
    }
    @ObservationIgnored var onBubbleSizeChange: (() -> Void)?

    /// The bubble panel's fixed size: big enough for the longest answer, invisible and
    /// click-through, so content is never clipped while it grows or animates.
    static let bubbleCanvas = CGSize(width: 420, height: 560)

    /// Changes every time a new set of pointers appears, to restart their animation.
    var pointerGeneration = 0

    /// Recent fast positions of the companion's arrowhead (global AppKit points), for
    /// the Sandevistan speed trail. Empty when the cursor is still or slow.
    var trail: [TrailPoint] = []
    /// Seconds a ghost stays visible.
    static let trailLifetime: TimeInterval = 0.32
}

struct TrailPoint: Equatable {
    var position: CGPoint
    var time: TimeInterval
    /// Increments per ghost so colours cycle along the trail.
    var index: Int
}
