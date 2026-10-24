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
        public var isPreRun: Bool {
            [.transcribing, .orderCheck, .elementPick, .buildingRequest].contains(self)
        }

        /// The answer run exists (streaming, or a snip's explanation is done).
        public var hasRun: Bool { [.streaming, .explained, .partsLook, .tourPrep].contains(self) }

        /// Past streaming: an answer's pointing/tour, or a snip's explanation-done phases.
        public var isPastStreaming: Bool { [.explained, .partsLook, .tourPrep, .tour].contains(self) }
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
        /// ⌥⌘: explain, or a double tap's chat. Peels what's working, as ⌃⌥ does: using ClickBait
        /// again never waits for the last thing to finish (user's rule, 2026-10-24).
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

    // MARK: Peeling on its own

    /// A highlight's or snip's explanation, a code answer, or a walkthrough being planned goes
    /// to the dock once it's still working after this, or at once when the user moves on, so
    /// they never wait to use ClickBait again (user's rule, 2026-10-24). Faster answers stay.
    public static let dockAfter: Duration = .seconds(1)
    /// A walkthrough always plans in the dock: by the cursor only while it gathers what it
    /// needs, with a lavender "planning…" pill held this long to be read (user's ask, 2026-10-24).
    public static let walkthroughDockAfter: Duration = .milliseconds(600)

    /// The two holds — Strawberry Red while a snip is worked out until its tour, Lavender while
    /// a walkthrough is planned until it starts — follow one set of rules (user's rule,
    /// 2026-10-14: "Lavender mode hold behavior must match Strawberry Red mode exactly"): still
    /// still working when the user moves on, it goes to the dock (if there's room); while held
    /// nothing is pointed at and no app is opened; when the hold ends the companion is back at
    /// the cursor; the result waits on the card for the user's go (`resumeAction`).
    public enum Hold: CaseIterable, Sendable {
        case snip, walkthrough
    }

    public static func holdPeels(_ hold: Hold, stillWorking: Bool, answeredAlready: Bool = false, hasRoom: Bool) -> Bool {
        stillWorking && !answeredAlready && hasRoom
    }

    /// While held: never.
    public static func mayPoint(during hold: Hold) -> Bool { false }
    public static func mayOpenApps(during hold: Hold) -> Bool { false }
    /// After the hold: the companion is back at the cursor (the peel's fresh one), not left at
    /// the dock.
    public static func rejoinsCursor(after hold: Hold) -> Bool { true }

    public static let walkthroughResumePrompt = "show me!"

    /// What the card offers to carry on where the hold left off.
    public static func resumeAction(_ hold: Hold) -> String {
        hold == .snip ? suggestedPartsPrompt : walkthroughResumePrompt
    }

    /// A first ⌥⌘ explanation or snip still working when the user moves on peels by
    /// itself, as ⌃⌥ would: an explanation while it streams, a snip until its tour starts
    /// (it then skips the tour). Spoken questions and follow-ups never do, nor anything when
    /// the dock is full (it just finishes in front).
    /// `answeredAlready`: the explanation was complete when the user moved on — an
    /// answer already in stays in front with the companion it has; no peel, no new companion
    /// at the cursor (user's rule, 2026-10-14).
    public static func autoPeels(_ situation: Situation, answeredAlready: Bool = false) -> Bool {
        guard situation.hasRoom, !answeredAlready else { return false }
        if situation.work == .snip {
            let working = [.streaming, .explained, .partsLook, .tourPrep].contains(situation.phase)
            return holdPeels(.snip, stillWorking: working, answeredAlready: answeredAlready, hasRoom: situation.hasRoom)
        }
        switch situation.work {
        case .answer: return situation.phase == .streaming
        case .snip: return [.streaming, .explained, .partsLook, .tourPrep].contains(situation.phase)
        }
    }

    /// The line shown instead of a tour whose snipped area no longer looks the same.
    public static let movedPill = "that's moved — snip it again to tour it"

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
