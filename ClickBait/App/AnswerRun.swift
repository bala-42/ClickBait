import Foundation
import ClickBaitCore

/// Ownership and output routing for one response stream. A run changes route once, when
/// peeled; it never derives ownership from mutable foreground coordinator state.
@MainActor
final class AnswerRun {
    enum Destination {
        case foreground
        case background(UUID)
    }

    let id: UUID
    let question: String
    let kind: BackgroundJob.Kind
    let homeBundleID: String?
    let homePID: Int32?
    let display: String
    var conversation: Conversation
    var snipMemory: AskCoordinator.SnipMemory?
    var chatMessages: [ChatModel.Message] = []
    var destination: Destination = .foreground
    var task: Task<Void, Never>?
    /// A snip's explanation, once complete (before its tour): what a peel keeps.
    var explanation: String?
    /// Set once known: whether the snip's parts tour was going to happen.
    var expectsTour: Bool?
    /// Adds this answer's turn to a conversation; set once the answer is parsed, so a snip
    /// peeled before its tour can still record it.
    var recordTurn: ((inout Conversation) -> Void)?

    init(id: UUID, question: String, kind: BackgroundJob.Kind, homeBundleID: String?, homePID: Int32?,
         display: String, conversation: Conversation) {
        self.id = id
        self.question = question
        self.kind = kind
        self.homeBundleID = homeBundleID
        self.homePID = homePID
        self.display = display
        self.conversation = conversation
    }
}

/// One spoken question or snip from the press (or the closed circle) to its end: how far it
/// has got, what it is known to be, and everything it must not share with the next question.
/// A peel before the answer's run exists (`jobID` with no run) sends the question to the background
/// while it carries on; the next question then starts with fresh coordinator state.
@MainActor
final class QuestionFlow {
    let work: PeelRule.Work
    /// Its place with the model: flipped to background when it goes to the dock, so a new
    /// question gets answered first (`ModelTurns`).
    let modelTurn = ModelTurn()
    var phase: PeelRule.Phase
    var kind: PeelRule.Kind = .unknown
    /// What it's doing before the answer starts, for its tile if it's sent away (C6).
    var stage: JobStage?
    /// The model's answer pointed at something (for `IntentRouter`'s shadow comparison).
    var pointed = false
    /// It became a walkthrough, in front, in the dock or written out (for the same comparison:
    /// a docked walkthrough isn't running when it's made, and was counted as an order).
    var walkthrough = false
    /// Captured at the press, so a newer question can't change what this one asks with.
    var provider: (any LLMProvider)?
    var context = ScreenContext()
    var homeBundleID: String?
    var homePID: Int32?
    /// In Chrome or Safari: the tab it was asked in, being read from the browser.
    var browserTab: Task<BrowserTab?, Never>?
    /// The highlighted text (a document's passage, code) it's about, kept for follow-ups.
    var documentText: String?
    /// The answer's run, once created.
    var run: AnswerRun?
    var task: Task<Void, Never>?
    /// What was heard, once transcribed.
    var heard: String?
    /// The job made by a peel, and whether the run has joined it. Set before the run exists
    /// when the press came early: the question carries on and joins its tile later.
    var jobID: UUID?
    /// Was sent to the background at some point: the foreground's chat is not this question's.
    var sentAway = false
    let startedAt = ContinuousClock.now
    /// ⌃⌥ was let go (the 350 ms tail may still be running).
    var released = false
    /// The recording, once stopped (the tail ended, or a peel ended it early).
    var samples: [Float]?
    var captureTask: Task<ScreenCapture, Error>?
    var snapshotTask: Task<AXSnapshot, Never>?
    var joined = false
    /// The open chat, handed over at a queued peel so the new question starts clean.
    var conversation: Conversation?
    var snipMemory: AskCoordinator.SnipMemory?
    var chatMessages: [ChatModel.Message] = []
    /// A snip's close-up geometry and text recognition, from `finishSnip` to `respond`.
    var pendingSnipView: (view: SnipView, text: Task<[TextBox], Never>, objects: Task<[FoundObject], Never>)?
    /// A snip's words inside what was marked, and where that is in the close-up (`AskRequest`).
    var snipWords: String?
    var snipMarked: Rect?

    init(work: PeelRule.Work, phase: PeelRule.Phase) {
        self.work = work
        self.phase = phase
    }
}
