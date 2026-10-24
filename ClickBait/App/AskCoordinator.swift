import AppKit
import AVFoundation
import ClickBaitCore
import Observation

/// A pointer resolved to real screen positions.
struct ScreenPointer: Equatable {
    var label: String
    /// Global AppKit point (bottom-left origin) — for overlay windows.
    var appKit: Point
    /// Global Quartz point (top-left origin) — for Accessibility hit-testing.
    var quartz: Point
    /// A tour part's outline around the point, in screen points: the triangle's tip stops
    /// at its edge instead of on top of the thing. Nil: the tip goes to the point.
    var outline: PartOutline? = nil
}

enum AskState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case error(String)
}

/// Runs one ask from hotkey press to answer: idle → listening → thinking → speaking.
/// Answers are spoken sentence by sentence as they stream in.
@MainActor
@Observable
final class AskCoordinator {
    /// Taps shorter than this are treated as accidental and dropped silently.
    static let minimumHold: Duration = .milliseconds(250)
    /// People let go of the keys while still saying the last word: keep listening a
    /// moment longer.
    static let releaseTail: Duration = .milliseconds(350)
    static let errorDisplayTime: Duration = .milliseconds(2500)

    var state: AskState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    @ObservationIgnored var onStateChange: ((AskState) -> Void)?
    /// Called with what Whisper heard.
    @ObservationIgnored var onTranscript: ((String) -> Void)?
    /// Called with the start of the highlighted text being explained (⌥⌘).
    @ObservationIgnored var onExplaining: ((String) -> Void)?
    /// A new chat bubble opens, showing the user's first message.
    @ObservationIgnored var onChatOpen: ((String) -> Void)?
    /// A follow-up was sent in the open chat (typed or spoken).
    @ObservationIgnored var onChatUserMessage: ((String) -> Void)?
    /// The model proposed a risky action: ask the user (the question to show).
    @ObservationIgnored var onConfirmRequest: ((String) -> Void)?
    /// The question is no longer pending (answered, replaced or dropped).
    @ObservationIgnored var onConfirmEnd: (() -> Void)?
    /// Set by ⌥⌘ + right-click so the following release of ⌥⌘ doesn't count as a tap.
    @ObservationIgnored var ignoreExplainRelease = false
    /// Single ⌥⌘ tap (explain) vs double tap (type to ask).
    @ObservationIgnored var explainTaps = DoubleTapDetector()
    /// A single tap explains at once but stays undoable until a second tap can no longer
    /// come; this ends that window (`commitExplain`).
    @ObservationIgnored var explainCommit: Task<Void, Never>?
    /// The next typed message is a done card's clicked suggestion: it goes to the dock once
    /// the user moves on, like a first explanation (user's rule, 2026-10-23). Read once
    /// by `sendTyped`.
    @ObservationIgnored var nextTypedIsSuggestion = false
    /// What goes to the dock if the user moves on while it's still working (`armMoveOn`).
    @ObservationIgnored var moveOnPeel: (() -> Void)?
    @ObservationIgnored var moveOnClicks: Any?
    /// The armed peel's id, so an old timer can't fire a newer one.
    @ObservationIgnored var moveOnArmed: UUID?
    @ObservationIgnored var moveOnSwitches: NSObjectProtocol?
    /// The chat a provisional explanation detached: still on screen, put back by
    /// `undoExplain`, closed by `commitExplain`.
    @ObservationIgnored var detachedChat: (conversation: Conversation, snipMemory: SnipMemory?)?
    /// An empty chat should open, ready to type into (⌥⌘ + right-click, double-tap ⌥⌘).
    @ObservationIgnored var onChatOpenForTyping: (() -> Void)?
    /// The open chat should take the keyboard.
    @ObservationIgnored var onChatFocus: (() -> Void)?
    /// Esc stopped an answer that was coming in (the chat stops showing it as busy).
    @ObservationIgnored var onStopped: (() -> Void)?
    /// A typed order was carried out: its confirmation, as the chat's reply.
    @ObservationIgnored var onChatReply: ((String) -> Void)?
    /// Something went wrong answering in the chat.
    @ObservationIgnored var onChatError: ((String) -> Void)?
    /// The chat closed from this side (a new ⌥⌘ explanation replaces it).
    @ObservationIgnored var onChatClose: (() -> Void)?
    /// Called with the spoken answer so far while it streams in.
    @ObservationIgnored var onPartialAnswer: ((String) -> Void)?
    /// Called when a spoken command starts running, with what it's doing.
    @ObservationIgnored var onActionStarted: ((String) -> Void)?
    /// Called after a spoken command ran, with a short confirmation.
    @ObservationIgnored var onActionDone: ((String) -> Void)?
    /// Named parts of a snipped thing to show one by one (the red tour).
    @ObservationIgnored var onTour: (([ScreenPointer]) -> Void)?
    /// A tour's names were checked against Wikipedia: its credit line, for the chat.
    @ObservationIgnored var onChatSource: ((String) -> Void)?
    /// The user started (true) or stopped marking part of the screen with ⌥⌘ held.
    @ObservationIgnored var onSnipMarking: ((Bool) -> Void)? {
        didSet { snipper.onMarkingChange = onSnipMarking }
    }
    /// A second, zoomed-in look corrected where some pointers are (same order).
    @ObservationIgnored var onPointersRefined: (([ScreenPointer]) -> Void)?
    /// Pointing before the model answers: the question names exactly one thing on screen.
    @ObservationIgnored var onInstantPointer: (([ScreenPointer]) -> Void)?
    /// The current answer already pointed instantly: its own pointers don't move the companion.
    @ObservationIgnored var pointedInstantly = false
    /// Called with the parsed answer and its pointers mapped to screen points.
    @ObservationIgnored var onAnswer: ((AssistantResponse, [ScreenPointer]) -> Void)?

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let speech: SpeechModelManager
    @ObservationIgnored let recorder = AudioRecorder()
    @ObservationIgnored let capturer = ScreenCapturer()
    @ObservationIgnored let snipper = SnipController()
    @ObservationIgnored var captureTask: Task<ScreenCapture, Error>?
    @ObservationIgnored var pressedAt: ContinuousClock.Instant?
    @ObservationIgnored var context = ScreenContext()
    @ObservationIgnored var frontmostPID: pid_t?
    @ObservationIgnored var frontmostBundleID: String?
    @ObservationIgnored var snapshotTask: Task<AXSnapshot, Never>?
    @ObservationIgnored var provider: (any LLMProvider)?
    @ObservationIgnored var errorResetTask: Task<Void, Never>?
    @ObservationIgnored var askTask: Task<Void, Never>?
    @ObservationIgnored var backgroundJobs: BackgroundJobs?
    @ObservationIgnored var activeAnswerRun: AnswerRun?
    /// The spoken question or snip in progress (nil when none): how far it has got and what it
    /// is known to be, which decides what ⌃⌥ does (`PeelRule`). A question sent to the
    /// background keeps its own flow; this one is then nil or the next question's.
    @ObservationIgnored var currentFlow: QuestionFlow?
    /// A queued peel turned out to be quick (a command, a walkthrough, an instant pick), or ⌃⌥
    /// came for something already known to be, or a returning snip's area has moved: the
    /// short pill, in the job's colour. `true` shows it at once; `false` waits until nothing
    /// else is being said.
    @ObservationIgnored var onQuickEnding: ((String, CompanionTone, Bool) -> Void)?
    @ObservationIgnored var onPeel: ((BackgroundJob) -> [ChatModel.Message])?
    @ObservationIgnored var onPeelRefused: (() -> Void)?
    /// The open chat bubble's memory. Nil when no bubble is open; dropped on close.
    @ObservationIgnored var conversation: Conversation?
    /// A reply is being fetched for the chat (blocks a second send).
    @ObservationIgnored var isAnswering = false
    /// The current answer flow owns shared busy state until a newer flow replaces it.
    @ObservationIgnored var answerFlowID: UUID?
    @ObservationIgnored var answeringOwnerID: UUID?
    @ObservationIgnored let speaker: Speaker
    /// When the user let go (or pressed ⌥⌘), for the time-to-first-audio log.
    @ObservationIgnored var answerStartedAt: ContinuousClock.Instant?

    init(settings: AppSettings, speech: SpeechModelManager) {
        self.settings = settings
        self.speech = speech
        speaker = Speaker(settings: settings)
        recorder.prepare()
        speaker.onStart = { [weak self] in
            guard let self, let started = answerStartedAt else { return }
            answerStartedAt = nil  // log once per answer; Preview in Settings isn't an answer
            Log.ask.notice("First audio \(String(describing: ContinuousClock.now - started), privacy: .public) after release")
        }
    }


    func handle(_ event: ChordDetector.Event) {
        switch event {
        case .askPressed: begin()
        case .askReleased:
            // Only the press that started listening has a question to finish; an ignored press
            // must not replace the task of the one being answered.
            guard state == .listening, let flow = currentFlow, flow.phase == .listening, !flow.released else { break }
            flow.released = true
            askTask = Task { await finish() }
        case .askCancelled: cancel(reason: "another key was pressed")
        case .explainPressed:
            // Busy answering: a tap still explains, but nothing to snip into.
            if state != .listening, state != .thinking, !isAnswering { snipper.begin() }
        case .explainReleased:
            // Letting go of ⌥⌘ after a right-click (type to ask) isn't a tap.
            if ignoreExplainRelease {
                ignoreExplainRelease = false
                explainTaps.reset()
                snipper.cancel()
                return
            }
            let armed = snipper.isArmed
            switch snipper.isActive ? snipper.end() : .tap {
            case .snip(let kind, let region, let path):
                explainTaps.reset()
                snip(kind, region: region, path: path)
            case .tap where armed:
                explainTaps.reset()
                Log.ask.notice("Snip armed but nothing marked; ignoring")
            case .tap:
                explainTapped()
            }
        case .explainCancelled:
            snipper.cancel()
            explainTaps.reset()
            ignoreExplainRelease = false
        case .dictatePressed, .dictateReleased, .dictateCancelled:
            break  // `DictationController`
        }
    }

    /// Tap ⌥⌘: explain the highlighted text. Double-tap ⌥⌘: open a chat to type into,
    /// the keyboard-only twin of ⌥⌘ + right-click (no selection needed).
    func explainTapped() {
        switch explainTaps.tap(at: ProcessInfo.processInfo.systemUptime) {
        case .first:
            onInvoked?()
            // Explain now (no waiting), but keep it undoable for the double-tap window. The
            // window opens first, so nothing of the explanation shows during it.
            explainCommit?.cancel()
            explainCommit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(DoubleTapDetector.defaultWindow))
                guard !Task.isCancelled else { return }
                self?.commitExplain()
            }
            explain()
        case .second:
            undoExplain()
            startTypedChat(trigger: "double-tap ⌥⌘")
        }
    }

    /// The double-tap window passed: the tap really was a single one.
    /// Inside the double-tap window: the explanation is working but not shown yet (a double
    /// tap must leave the companion blue and still, not flash orange and spin).
    var isExplainProvisional: Bool { explainCommit != nil }
    /// The selection read during the window, shown once it's committed.
    @ObservationIgnored var pendingExcerpt: String?
    /// The chat the explanation started during the window (its first line), opened at commit.
    @ObservationIgnored var explainChat: String?

    func commitExplain() {
        explainCommit = nil
        // Now show what was held back: the thinking state, and the excerpt if it's in.
        onStateChange?(state)
        if let excerpt = pendingExcerpt {
            pendingExcerpt = nil
            onExplaining?(excerpt)
        }
        // The old chat goes first: closing it after opening the explanation's chat closed
        // the new one instead (same window), so the explanation never appeared.
        if detachedChat != nil {
            detachedChat = nil
            onChatClose?()
        }
        if let display = explainChat {
            explainChat = nil
            onChatOpen?(display)
        }
    }

    /// A second tap (or Esc) inside the window: drop the explanation quietly and put back
    /// the chat it had detached, as if the first tap never happened.
    func undoExplain() {
        explainCommit?.cancel()
        explainCommit = nil
        pendingExcerpt = nil
        if explainChat != nil {
            // The explanation had started its own chat: gone with it.
            explainChat = nil
            conversation = nil
            snipMemory = nil
            chatShown = false
        }
        if state == .thinking || isAnswering {
            askTask?.cancel()
            askTask = nil
            invalidateAnswerFlow()
            state = .idle
            Log.ask.notice("Explain undone (second tap)")
        }
        if let detached = detachedChat {
            conversation = detached.conversation
            snipMemory = detached.snipMemory
            chatShown = true
            detachedChat = nil
        }
    }

    /// The overlay dismissed the answer (click, Escape or timeout). If it was still
    /// streaming in, stop the request too so it doesn't pop back up.
    func answerDismissed() {
        speaker.stop()
        askTask?.cancel()
        askTask = nil
        invalidateAnswerFlow()
        if state == .speaking || state == .thinking { state = .idle }
    }


    // MARK: - State used by the flows in the AskCoordinator+*.swift files

    /// The microphone is on for a card's voice panel (not ⌃⌥ listening).
    @ObservationIgnored var isCardRecording = false
    /// The microphone is on for dictation, or its words are still being turned into text.
    @ObservationIgnored var isDictating = false
    var routeCache = IntentRouter.Cache()
    var shadowTask: Task<Void, Never>?
    /// A risky action the model proposed, waiting for the user's yes.
    @ObservationIgnored var pendingAction: (request: ActionRequest, speak: Bool, inChat: Bool)?
    /// A reminder waiting for its day (Today / Tomorrow / a spoken or typed day).
    @ObservationIgnored var pendingReminder: (request: ActionRequest, speak: Bool, inChat: Bool)?
    /// A reminder's "when?" card should be shown: the question, the buttons, a hint.
    @ObservationIgnored var onReminderDayRequest: ((String, [String], String?) -> Void)?
    /// Set by the app delegate: walks the user through multi-step how-tos.
    @ObservationIgnored var tutorial: TutorialController?
    /// The app the user was in when a tutorial had to open another one ("back to Notes?").
    @ObservationIgnored var tutorialReturnApp: NSRunningApplication?
    /// Setup (opening an app for a tutorial) is over: the green "Opening…" can go.
    @ObservationIgnored var onSetupFinished: (() -> Void)?
    /// A walkthrough is being planned (true: lavender, spinning), or won't happen (false).
    @ObservationIgnored var onTutorialPlanning: ((Bool) -> Void)?
    /// The walkthrough being planned now was sent to the dock (Lavender's hold, as a snip's
    /// Strawberry Red one): its plan goes to that tile, never to the foreground.
    @ObservationIgnored var walkthroughJobID: UUID?
    /// Planning is under way and may be held in the dock (`PeelRule.holdPeels`).
    @ObservationIgnored var walkthroughPlanning = false
    /// A walkthrough was just declined: the answer that follows is words only — no app is
    /// opened and nothing is pointed at (2026-10-14: after a lapsed "show me in Safari!" the
    /// fallback answer opened Safari and pointed at its menu bar).
    @ObservationIgnored var answerInWordsOnly = false
    /// A hotkey brought ClickBait up (⌃⌥ held, ⌥⌘ tapped or double-tapped): the chat's
    /// place is where the companion is at this moment.
    @ObservationIgnored var onInvoked: (() -> Void)?
    @ObservationIgnored var tutorialPlanningShown = false
    /// "[show me!] [✕]" should be offered before a walkthrough starts (the button's words).
    @ObservationIgnored var onTutorialOffer: ((String) -> Void)?
    /// A walkthrough was declined: its steps, written out for the chat.
    @ObservationIgnored var onStepsWritten: ((String) -> Void)?
    @ObservationIgnored var pendingOffer: CheckedContinuation<Bool, Never>?
    /// Green setup: open the app the task needs and wait until it's in front with its
    /// menus readable (a cold launch takes a few seconds). Then a fresh look at the screen.
    /// Opening or switching apps for a walkthrough: the chat goes along (its checklist).
    @ObservationIgnored var isOpeningAppForTutorial = false
    /// Explains the part of the screen the user circled or boxed, in a chat bubble like
    /// a highlighted-text explanation.
    /// A snip is being answered (true), so thinking stays red; false once it's over.
    @ObservationIgnored var onSnipAnswering: ((Bool) -> Void)?
    /// The snip a chat started from: follow-ups resend its close-up and context picture.
    @ObservationIgnored var snipMemory: SnipMemory?
    /// Whether the chat bubble is on screen. A spoken question doesn't open one until
    /// its answer is in — and not at all when the answer points somewhere: the
    /// companion guides and the answer is spoken, so a chat would just be clutter.
    var chatShown = false
    /// A close-up look is running after an answer (it can be dropped at any time).
    @ObservationIgnored var isRefining = false
    @ObservationIgnored var refiningOwnerID: UUID?
}
