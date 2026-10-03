import ClickBaitCore
import Foundation
import Observation
import SwiftUI

/// The synchronized colour states shared by the companion triangle and the chat banner.
enum CompanionTone: Equatable {
    /// Azure (#007FFF): idle, following the cursor.
    case idle
    /// Mango Orange: listening, thinking, explaining (pulses).
    case processing
    /// Shamrock Green: Mac system actions and document/file processing.
    case action
    /// Strawberry Red: circling and snipping (roadmap phase C).
    case capture

    var color: Color {
        switch self {
        case .idle: Color(red: 0, green: 127.0 / 255, blue: 1.0)
        case .processing: Color(red: 1.0, green: 0.62, blue: 0.13)
        case .action: Color(red: 0.0, green: 0.62, blue: 0.38)
        case .capture: Color(red: 0.98, green: 0.22, blue: 0.36)
        }
    }
}

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
        /// A spoken command is running (file actions can take a while).
        case working(String)
        /// A spoken command was carried out.
        case done(String)
        case error(String)

        /// A result or a problem: shown as a tiny pill. Everything else is just the
        /// triangle's colour and pulse.
        var hasWords: Bool {
            switch self {
            case .answer, .done, .error: true
            case .thinking(let heard): heard != nil  // what was heard, so mishearing shows
            default: false
            }
        }
    }

    var bubble: Bubble = .idle

    /// ⌥⌘ is held and the user is circling or boxing something.
    var isSnipping = false

    var tone: CompanionTone {
        if isSnipping { return .capture }
        return switch bubble {
        case .idle, .answer, .error: .idle
        case .listening, .thinking, .explaining: .processing
        case .working, .done: .action
        }
    }

    /// The triangle pulses while something is in progress.
    var isPulsing: Bool {
        if isSnipping { return true }
        return switch bubble {
        case .listening, .thinking, .explaining, .working: true
        default: isGuiding  // a gentle beat draws the eye to the target
        }
    }
    /// The triangle's rotation in degrees (0 = vertex up, clockwise). Aimed up-left at
    /// the cursor normally; turned toward a target while guiding.
    var triangleAngle: Double = CompanionTriangle.restingAngle
    /// Detached from the cursor, pointing at a target from an answer.
    var isGuiding = false
    /// Shown beside the triangle while guiding, e.g. "1/2 · Share".
    var guideLabel: String?
    /// The element's name, for VoiceOver (the visible label is just "this one!").
    var guideTarget: String?
    var guideLabelSize: CGSize = .zero
    static let guideLabelCanvas = CGSize(width: 320, height: 40)
    /// The companion's drawn size. Ignored by observation: the controller reacts through
    /// `onBubbleSizeChange` instead, and the view never reads it.
    @ObservationIgnored var bubbleSize: CGSize = .zero {
        didSet { if bubbleSize != oldValue { onBubbleSizeChange?() } }
    }
    @ObservationIgnored var onBubbleSizeChange: (() -> Void)?

    /// The bubble panel's fixed size: big enough for the longest answer, invisible and
    /// click-through, so content is never clipped while it grows or animates.
    static let bubbleCanvas = CGSize(width: 420, height: 560)

}
