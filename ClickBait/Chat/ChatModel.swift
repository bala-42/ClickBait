import SwiftUI
import Foundation
import Observation

/// What a chat bubble shows. Owned by `ChatController`; its conversation memory lives in
/// `AskCoordinator` and disappears with the bubble.
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
    }

    var messages: [Message] = []
    var draft = ""
    /// Waiting for (or streaming) a reply: sending is disabled meanwhile.
    var isBusy = false
    /// The chat is shrinking away (then its window closes).
    var isClosing = false
    /// Where the companion is, as a point in the card (0…1 each way): the card grows out
    /// of it on opening and shrinks back into it on closing.
    var companionAnchor = UnitPoint.topLeading
    /// Bumped to put the cursor in the text field (a chat opened to type into).
    var focusRequest = 0

    @ObservationIgnored var onSend: ((String) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
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
