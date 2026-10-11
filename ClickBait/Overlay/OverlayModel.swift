import ClickBaitCore
import Foundation
import Observation
import SwiftUI

/// The synchronized colour states shared by the companion triangle and the chat banner.
enum CompanionTone: Equatable {
    /// Azure (#007FFF): idle, following the cursor.
    case idle
    /// Pumpkin (#FF7518): listening, thinking, explaining. Was marigold (#EAA221):
    /// white pill text is ~25% more readable on this, and it reads clearly against blue.
    case processing
    /// Shamrock Green: Mac system actions and document/file processing.
    case action
    /// Strawberry Red: circling and snipping (roadmap phase C).
    case capture
    /// Lavender (#B57EDC): a guided tutorial is running.
    case tutorial

    var color: Color {
        switch self {
        case .idle: Color(red: 0, green: 127.0 / 255, blue: 1.0)
        case .processing: Color(red: 1.0, green: 117.0 / 255, blue: 24.0 / 255)
        case .action: Color(red: 0.0, green: 0.62, blue: 0.38)
        case .capture: Color(red: 0.98, green: 0.22, blue: 0.36)
        case .tutorial: Color(red: 181.0 / 255, green: 126.0 / 255, blue: 220.0 / 255)
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
        /// A tutorial step whose target isn't on screen: its instruction by the cursor.
        case hint(String)
        /// A background ClickBait finished: its summary, in the job's colour.
        case jobResult(String, CompanionTone)

        /// A result or a problem: shown as a tiny pill. Everything else is just the
        /// triangle's colour and pulse.
        var hasWords: Bool {
            switch self {
            case .answer, .done, .error, .hint, .working, .jobResult: true  // working: "opening safari…"
            case .thinking(let heard): heard != nil  // what was heard, so mishearing shows
            default: false
            }
        }
    }

    var bubble: Bubble = .idle
    /// Incremented when an answer peels away so the companion can pop back in for the
    /// next listen without tying the animation to the background job's lifetime.
    var companionPop = 0
    /// How long the companion stays hidden before popping in: a peel's copy grows where it
    /// is first (`AgentDock.growTime`).
    var companionPopDelay: Double = 0

    /// How loud the user is right now while listening, 0…1 (drives the waveform).
    var waveLevel: Double = 0
    /// ⌥⌘ is held and the user is circling or boxing something.
    var isSnipping = false
    /// Working out what was snipped: thinking stays red (and spins).
    var isSnipThinking = false
    /// Touring the named parts of a snipped thing (red, like snipping).
    var isTouring = false
    /// A guided tutorial is running: everything is lavender.
    var isTutoring = false
    /// The guiding triangle has arrived at its target (it pulses only then).
    var isGuideSettled = false
    /// The flight's swell (1 at rest, up to 1.3 mid-flight; `FlightArc.scale`).
    var flightScale: CGFloat = 1

    var tone: CompanionTone {
        // Red from the circling until the parts are pointed at (or there's nothing to point).
        if isSnipping || isTouring || isSnipThinking { return .capture }
        // Opening or switching apps is green, also inside a walkthrough (lavender hid it).
        // (The walkthrough's own "done" tick stays lavender.)
        switch bubble {
        case .working: return .action
        case .done(let text) where text != Self.walkthroughDone: return .action
        default: break
        }
        if isTutoring { return .tutorial }
        if isGuiding { return .idle }  // pointing is blue, even while the words are still coming
        return switch bubble {
        case .idle, .answer, .error, .hint, .jobResult: .idle  // a job's result pill wears the job's colour; the companion stays Azure
        case .listening, .thinking, .explaining: .processing
        case .working, .done: .action
        }
    }

    /// The triangle pulses while something is in progress (not thinking: that spins).
    var isPulsing: Bool {
        if isSnipping { return true }
        return switch bubble {
        case .working: true  // listening shows the waveform instead
        // A gentle beat once it's there, not while gliding — and never on a red parts tour,
        // which holds steady on each part (user's rule, 2026-10-11).
        default: isGuiding && isGuideSettled && !isTouring
        }
    }

    /// A walkthrough is checking what's next ("checking…"): it spins where it points.
    var isTutorialChecking = false
    /// The tick a finished walkthrough shows (lavender, unlike other "done" pills).
    static let walkthroughDone = "done"

    /// The AI is thinking: the triangle turns a third at a time with a springy overshoot.
    var isSpinning: Bool {
        if isTutoring, isTutorialChecking { return true }
        if isSnipThinking, !isGuiding, !isTouring { return true }  // working out a snip, until the tour
        guard !isSnipping, !isGuiding else { return false }
        return switch bubble {
        case .thinking, .explaining: true
        default: false
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
    static let guideLabelCanvas = CGSize(width: 320, height: 220)
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
