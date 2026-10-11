import Foundation
import ClickBaitCore
import Observation

/// Progress that can be rendered without coupling a capsule to a particular job kind.
enum JobProgress: Equatable {
    case counted(done: Int, total: Int)
    case uncounted
}

@MainActor
@Observable
final class BackgroundJobs {
    struct Entry: Identifiable {
        var job: BackgroundJob
        var task: Task<Void, Never>?
        var chatMessages: [ChatModel.Message] = []
        var snipMemory: AskCoordinator.SnipMemory?
        var progress: JobProgress = .uncounted
        /// Its card has been opened since it finished: the tile stops pulsing.
        var seen = false
        var id: UUID { job.id }
    }

    private(set) var entries: [Entry] = [] {
        didSet { onChange?(entries) }
    }
    var onChange: (([Entry]) -> Void)?

    var count: Int { entries.count }
    var hasRoom: Bool { count < AgentDock.maxTiles }

    @discardableResult
    func add(_ job: BackgroundJob, task: Task<Void, Never>?) -> Bool {
        guard hasRoom, !entries.contains(where: { $0.id == job.id }) else { return false }
        entries.insert(Entry(job: job, task: task), at: 0)  // newest on top
        return true
    }

    func append(_ text: String, to id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].job.append(text)
    }

    func complete(_ id: UUID, answer: String, conversation: Conversation) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].job.complete(answer: answer, conversation: conversation)
        entries[index].task = nil
    }

    func fail(_ id: UUID, reason: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].job.fail(reason)
        entries[index].task = nil
        cancelSnipWork(in: entries[index])
        entries[index].snipMemory = nil
    }

    func markSeen(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].job.isWorking,
              !entries[index].seen else { return }
        entries[index].seen = true
    }

    func setSnipMemory(_ memory: AskCoordinator.SnipMemory?, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].snipMemory = memory
    }

    func setTask(_ task: Task<Void, Never>?, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].task = task
    }

    func setChatMessages(_ messages: [ChatModel.Message], for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].chatMessages = messages
    }

    func stop(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].job.isWorking else { return }
        entries[index].task?.cancel()
        cancelSnipWork(in: entries[index])
        entries.remove(at: index)
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func job(_ id: UUID) -> BackgroundJob? {
        entries.first(where: { $0.id == id })?.job
    }

    func removeAll() {
        entries.forEach {
            $0.task?.cancel()
            cancelSnipWork(in: $0)
        }
        entries.removeAll()
    }

    private func cancelSnipWork(in entry: Entry) {
        entry.snipMemory?.text?.cancel()
        entry.snipMemory?.objects?.cancel()
        entry.snipMemory?.reference?.cancel()
    }
}
