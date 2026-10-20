import Foundation

/// What a background job is doing before its answer starts writing, for the running tile's
/// line (C6, 2026-10-20): a model answer is silent for ~2–8 s otherwise.
public enum JobStage: Equatable, Sendable {
    case readingScreen
    case thinking
    case lookingUp
    case planningSteps

    public var text: String {
        switch self {
        case .readingScreen: "Reading your screen…"
        case .thinking: "Thinking…"
        case .lookingUp: "Looking it up on the web…"
        case .planningSteps: "Planning the steps…"
        }
    }
}
