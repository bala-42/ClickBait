import ClickBaitCore
import SwiftUI
import Foundation
import Observation

/// What a chat bubble shows. Owned by `ChatController`; its conversation memory lives in
/// `AskCoordinator`. The messages themselves stay for the session (user's ask, 2026-11-02:
/// "persistent like the file shelf", one history whether asked by ⌃⌥, ⌥⌘ or the notch): a new
/// chat starts at `sessionStart`, the ones before it are history.
@MainActor
@Observable
final class ChatModel {
    struct Message: Identifiable, Equatable {
        enum Role: Equatable {
            case user
            case assistant
            case error
        }

        let id = UUID()
        var role: Role
        var text: String
        /// Smart search's finds, shown as a results card under the text (`SearchResultsView`).
        var results: [SmartSearch.Item] = []
    }

    var messages: [Message] = []
    /// Where this chat's own messages begin; earlier ones are the session's history.
    var sessionStart = 0
    /// This chat's own messages (what Save keeps and the dock takes).
    var current: [Message] { Array(messages[min(sessionStart, messages.count)...]) }
    /// The session's history kept: the newest this many messages.
    static let historyLimit = 60

    /// A new chat: what was said stays above as history.
    func startSession() {
        if messages.count > Self.historyLimit { messages.removeFirst(messages.count - Self.historyLimit) }
        sessionStart = messages.count
    }

    /// Everything forgotten (the notch's Clear).
    func clearHistory() {
        guard !isBusy else { return }
        messages = []
        sessionStart = 0
    }
    var draft = ""
    /// Waiting for (or streaming) a reply: sending is disabled meanwhile.
    var isBusy = false
    /// The chat is shrinking away (then its window closes).
    var isClosing = false
    /// Tucked into the companion while an answer is on its way (the panel is hidden but
    /// keeps its place); it grows back out when the answer starts arriving.
    var isTucked = false
    /// Near the right screen edge: logo at the card's top-right, so it can still sit on the
    /// companion with the card opening to its left.
    var isFlipped = false
    /// The logo's centre measured in the card (from its top-left, y down); nil until laid out.
    @ObservationIgnored var logoOffset: CGPoint? {
        didSet { if logoOffset != oldValue { onLogoMove?() } }
    }
    @ObservationIgnored var onLogoMove: (() -> Void)?
    /// Where the companion is, as a point in the card (0…1 each way): the card grows out
    /// of it on opening and shrinks back into it on closing.
    var companionAnchor = UnitPoint.topLeading
    /// Bumped to put the cursor in the text field (a chat opened to type into).
    var focusRequest = 0

    @ObservationIgnored var onSend: ((String) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    /// The header's Remember and Save buttons (C5): shown once there's an answer.
    @ObservationIgnored var onRemember: (() -> Void)?
    @ObservationIgnored var onSaveAnswer: (() -> Void)?
    /// Set for a moment after Save or Remember worked ("Saved", "Remembered").
    var keptNote: String?
    var canKeep: Bool { !isBusy && messages.contains { $0.role == .assistant } }
    /// The card's drawn size, so the window can fit it exactly (the space around a
    /// clickable window would otherwise swallow clicks).
    @ObservationIgnored var cardSize: CGSize = .zero {
        didSet { if cardSize != oldValue { onCardSizeChange?() } }
    }
    @ObservationIgnored var onCardSizeChange: (() -> Void)?

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        draft = ""
        onSend?(text)
    }

    func addUser(_ text: String) {
        messages.append(Message(role: .user, text: text))
    }

    /// Updates the reply being streamed in, starting a new one if needed.
    func setAssistant(_ text: String) {
        if let last = messages.indices.last, messages[last].role == .assistant, isBusy {
            messages[last].text = text
        } else {
            messages.append(Message(role: .assistant, text: text))
        }
    }

    /// Drops a forgotten find from every results card.
    func removeResult(_ id: String) {
        for index in messages.indices { messages[index].results.removeAll { $0.id == id } }
    }

    /// Puts smart search's finds under the latest reply.
    func setResults(_ items: [SmartSearch.Item]) {
        if let last = messages.indices.last(where: { messages[$0].role == .assistant }) { messages[last].results = items }
    }

    /// Rewrites the latest reply (a tutorial's checklist ticking along).
    func replaceLastAssistant(_ text: String) {
        if let last = messages.indices.last(where: { messages[$0].role == .assistant }) {
            messages[last].text = text
        } else {
            messages.append(Message(role: .assistant, text: text))
        }
    }

    func addError(_ text: String) {
        messages.append(Message(role: .error, text: text))
    }
}
