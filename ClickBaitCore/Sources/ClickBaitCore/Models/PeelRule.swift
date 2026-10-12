import Foundation

/// What a ⌃⌥ press (or a ⌥⌘ press) does while a question or snip is in progress, and how a
/// queued peel ends. Orange means sendable: any press during the orange time either peels,
/// waits to peel, or says why not. Never nothing. Pure: the app acts on it and logs it.
public enum PeelRule {
    /// How far the foreground work has got. Spoken questions run idle → listening →
    /// transcribing → orderCheck → elementPick → buildingRequest → streaming; a snip starts
    /// at buildingRequest (its circle is closed), streams its explanation, then
    /// explained → partsLook → tourPrep → tour.
    public enum Phase: Equatable, Sendable {
        case idle
        case listening
        case transcribing
        /// Deciding whether the words are a command (orders, walkthroughs).
        case orderCheck
        /// Picking an element from the on-screen list. It can fail and fall through to the model.
        case elementPick
        case buildingRequest
        case streaming
        /// A snip's explanation is complete; its parts tour has not started.
        case explained
        case partsLook
        /// Red tour prep: marks are being placed.
        case tourPrep
        case tour

        /// Between the words being heard and the answer's model request starting.
        var isPreRun: Bool {
            [.transcribing, .orderCheck, .elementPick, .buildingRequest].contains(self)
        }

        /// The answer run exists (streaming, or a snip's explanation is done).
        var hasRun: Bool { [.streaming, .explained, .partsLook, .tourPrep].contains(self) }

        /// Past streaming: an answer's pointing/tour, or a snip's explanation-done phases.
        var isPastStreaming: Bool { [.explained, .partsLook, .tourPrep, .tour].contains(self) }
    }

    public enum Work: Equatable, Sendable {
        case answer
        case snip
    }

    /// What the question is known to be. `unknown` until the app can tell; a rule-recognised
    /// command or an exact-match instant pointer may be known in any pre-run phase.
    public enum Kind: Equatable, Sendable {
        case unknown
        case modelAnswer
        case command
        case instantPick
    }

    public enum Trigger: Equatable, Sendable {
        /// ⌃⌥: ask a question, or peel the one in progress.
        case chord
        /// ⌥⌘: explain; never peels.
        case explain
    }

    public struct Situation: Equatable, Sendable {
        public var phase: Phase
        public var work: Work
        public var kind: Kind
        /// The dock has a free slot (`BackgroundJobs.hasRoom`, max 3).
        public var hasRoom: Bool

        public init(phase: Phase, work: Work = .answer, kind: Kind = .unknown, hasRoom: Bool = true) {
            self.phase = phase
            self.work = work
            self.kind = kind
            self.hasRoom = hasRoom
        }
    }

    public enum Reason: Equatable, Sendable {
        case alreadyListening
        case threesACrowd
        case busy

        /// Short text for "⌃⌥ ignored: <reason>" / "⌥⌘ ignored: <reason>" log lines.
        public var logText: String {
            switch self {
            case .alreadyListening: "already listening"
            case .threesACrowd: "three's a crowd"
            case .busy: "busy"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The press is a normal one: ⌃⌥ listens (ending any pointing or tour), ⌥⌘ explains.
        case startNew
        /// Peel the running answer now; the same press is the next question.
        case peelNow
        /// The answer run doesn't exist yet: make the tile now, the run joins it later
        /// (see `resolution(of:)` for how it can turn out).
        case peelWhenReady
        /// The work is known to end without a model answer: say so, send nothing away.
        case tooQuick
        case ignore(Reason)
    }

    /// The pill when a queued peel turned out to be a command or an instant pick.
    public static let quickPill = "that one was quick — nothing to send away"

    /// Known-quick work wins over a full dock (`tooQuick` before `threesACrowd`): nothing
    /// would be sent away anyway. A snip's running tour, and an answer past streaming, are
    /// not peelable: a new question (or a ⌥⌘ explanation) just starts and ends them, as today.
    public static func outcome(of trigger: Trigger, in situation: Situation) -> Outcome {
        let phase = situation.phase
        if phase == .idle { return .startNew }
        if phase == .listening { return .ignore(.alreadyListening) }
        if phase == .tour || (phase.isPastStreaming && situation.work == .answer) { return .startNew }
        guard trigger == .chord else { return .ignore(.busy) }
        if phase.isPreRun, [.command, .instantPick].contains(situation.kind) { return .tooQuick }
        guard situation.hasRoom else { return .ignore(.threesACrowd) }
        return phase.hasRun ? .peelNow : .peelWhenReady
    }

    /// A snip peeled before its tour starts keeps its explanation in the done card, skips the
    /// tour, and suggests "show me the parts".
    public static func skipsTourAndSuggestsParts(_ situation: Situation) -> Bool {
        situation.work == .snip && [.explained, .partsLook, .tourPrep].contains(situation.phase)
    }

    public static let suggestedPartsPrompt = "show me the parts"

    // MARK: A queued peel resolving

    /// What the question turned out to be.
    public enum Ending: Equatable, Sendable {
        case modelAnswer
        case command
        /// Answered from the element list, without the model. `foregroundBusy`: another
        /// question is being answered in the foreground.
        case instantPick(foregroundBusy: Bool)
    }

    public enum Resolution: Equatable, Sendable {
        /// The job stays in the dock and finishes in the background.
        case joinTile
        /// Run the command in the foreground; the tile goes.
        case runCommand
        /// Point at the element now; the tile goes.
        case pointNow
        /// Busy: give the pick as a "go there!" result instead; the tile goes.
        case goThereResult

        public var removesTile: Bool { self != .joinTile }
        public var pill: String? { removesTile ? PeelRule.quickPill : nil }
    }

    public static func resolution(of ending: Ending) -> Resolution {
        switch ending {
        case .modelAnswer: .joinTile
        case .command: .runCommand
        case .instantPick(let busy): busy ? .goThereResult : .pointNow
        }
    }
}
