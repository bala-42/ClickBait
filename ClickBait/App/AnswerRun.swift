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
