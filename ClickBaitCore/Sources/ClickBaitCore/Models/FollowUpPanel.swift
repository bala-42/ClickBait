import Foundation

/// A card's mini-chat (user's requests, 2026-10-14): one conversation at the bottom of the
/// card that takes both typing and voice, and stays. "text" opens it with the field focused;
/// "voice" opens it and records — the voice button itself turns into the waveform — and a
/// second press stops: the words go into the field to edit, then send (never sent unheard).
/// Its chevron or Escape folds it. A send keeps it open; the card folding keeps it and its
/// draft (only a recording is dropped). What's sent is asked in the dock, so the job works
/// again in its tile. Pure: the card draws it, the app records and asks.
public struct FollowUpPanel: Equatable, Sendable {
    /// The card's two buttons.
    public enum Mode: Equatable, Sendable { case text, voice }

    public enum Voice: Equatable, Sendable {
        case ready
        /// The microphone starting.
        case starting
        case recording
        /// Stopped; Whisper is turning it into words.
        case transcribing
        /// Couldn't record or hear anything: the reason; voice tries again.
        case failed(String)

        public var isBusy: Bool { [.starting, .recording, .transcribing].contains(self) }
    }

    /// What the app must do after a change.
    public enum Effect: Equatable, Sendable {
        case none
        case startRecording
        /// Folding or giving up mid-recording: throw the recording away.
        case cancelRecording
        case stopRecording
        /// Ask this in the dock.
        case send(String)
    }

    public static let emptyHint = "Type or say a question first."
    public static let silentHint = "Didn't hear anything. Press voice to try again."
    public static let busyHint = "Wait for this answer first."
    public static let recordingHint = "Press voice to stop recording first."

    public private(set) var isOpen = false
    public private(set) var voice: Voice = .ready
    public var draft = ""
    /// Shown under the input (an empty or refused send).
    public private(set) var hint: String?

    public init() {}

    public var canSend: Bool {
        isOpen && !voice.isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "text" opens it (the field takes the keyboard); "voice" opens it and starts or stops
    /// recording — while the mic starts it gives up, while transcribing it waits.
    public mutating func tap(_ tapped: Mode) -> Effect {
        isOpen = true
        hint = nil
        guard tapped == .voice else { return .none }
        switch voice {
        case .ready, .failed:
            voice = .starting
            return .startRecording
        case .starting:
            voice = .ready
            return .cancelRecording
        case .recording:
            voice = .transcribing
            return .stopRecording
        case .transcribing:
            return .none
        }
    }

    /// The chevron or Escape. The draft stays for next time.
    public mutating func collapse() -> Effect {
        let leaving = dropRecording()
        isOpen = false
        hint = nil
        return leaving
    }

    /// The card folded: the chat stays open for when it reopens; a recording doesn't.
    public mutating func pause() -> Effect {
        dropRecording()
    }

    /// Return or send. `answering`: the last one isn't back yet.
    public mutating func submit(answering: Bool = false) -> Effect {
        guard isOpen else { return .none }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            hint = Self.emptyHint
        } else if voice.isBusy {
            hint = Self.recordingHint
        } else if answering {
            hint = Self.busyHint
        } else {
            draft = ""
            hint = nil
            return .send(text)
        }
        return .none
    }

    /// The app couldn't ask it: the words go back in the field with the reason.
    public mutating func sendFailed(_ text: String, reason: String) {
        isOpen = true
        draft = text
        hint = reason
    }

    public mutating func recordingStarted() {
        if voice == .starting { voice = .recording }
    }

    public mutating func recordingFailed(_ reason: String) {
        if voice.isBusy { voice = .failed(reason) }
    }

    /// The words heard (empty: nothing heard): added to the field to review, not sent.
    public mutating func transcribed(_ text: String) {
        guard voice == .transcribing else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            voice = .failed(Self.silentHint)
            return
        }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = typed.isEmpty ? words : typed + " " + words
        voice = .ready
    }

    @discardableResult
    private mutating func dropRecording() -> Effect {
        guard voice.isBusy else { return .none }
        voice = .ready
        return .cancelRecording
    }
}
