import Foundation

/// A memory-only task that can finish while the foreground companion handles another ask.
public struct BackgroundJob: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case answer
        case snip
    }

    public enum Status: Equatable, Sendable {
        case working
        case done(summary: String)
        case failed(reason: String)
        case stopped
    }

    public let id: UUID
    /// What was asked. A spoken question sent away before it was transcribed starts with a
    /// placeholder and is renamed once heard.
    public private(set) var question: String
    public let kind: Kind
    public let homeBundleID: String?
    public let homePID: Int32?
    /// The window it was asked in (title and frame when asked), for "go there!" to raise
    /// that window rather than whichever of the app's is in front (`HomeWindow.best`).
    public var homeWindowTitle: String?
    public var homeWindowFrame: Rect?
    /// In Chrome or Safari, the exact tab (`BrowserTab`): "go there!" asks the browser for it.
    public var homeTab: BrowserTab?
    public var conversation: Conversation
    public private(set) var status: Status
    public private(set) var answer: String

    public init(question: String, kind: Kind, homeBundleID: String?, homePID: Int32?, conversation: Conversation) {
        id = UUID()
        self.question = question
        self.kind = kind
        self.homeBundleID = homeBundleID
        self.homePID = homePID
        self.conversation = conversation
        status = .working
        answer = ""
    }

    public var isWorking: Bool { status == .working }

    public mutating func rename(_ question: String) {
        self.question = question
    }

    public mutating func append(_ text: String) {
        guard isWorking else { return }
        answer += text
    }

    public mutating func complete(answer: String, conversation: Conversation) {
        complete(summary: JobSummary.make(from: answer), answer: answer, conversation: conversation)
    }

    public mutating func complete(summary: String, answer: String, conversation: Conversation) {
        guard isWorking else { return }
        self.answer = answer
        self.conversation = conversation
        status = .done(summary: summary)
    }

    /// A follow-up asked from the done card's mini-chat: working again in the same tile,
    /// titled with the new question; the conversation carries on.
    public mutating func reopen(asking question: String) {
        guard case .done = status else { return }
        self.question = question
        answer = ""
        status = .working
    }

    public mutating func fail(_ reason: String) {
        guard isWorking else { return }
        status = .failed(reason: reason)
    }

    public mutating func stop() {
        guard isWorking else { return }
        status = .stopped
    }
}
