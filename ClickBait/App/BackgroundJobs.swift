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
        /// What the answer has said so far (its spoken text), for the running card's line.
        var liveText = ""
        /// "suggested next:" for a done card: nil until asked (when it first opens).
        var suggestions: [String]?
        /// A suggestion that comes before the asked-for ones (a snip peeled before its tour offers
        /// "show me the parts").
        var leadingSuggestion: String?
        /// Its card has been opened since it finished: the tile stops pulsing.
        var seen = false
        var id: UUID { job.id }

        /// What a done card offers: the leading one, then the asked-for ones, without repeats.
        var offeredSuggestions: [String] {
            ([leadingSuggestion].compactMap { $0 } + (suggestions ?? [])).reduce(into: []) {
                if !$0.contains($1) { $0.append($1) }
            }
        }

        /// Everything a tile or card shows is the same.
        func looksSame(as other: Entry) -> Bool {
            job == other.job && liveText == other.liveText && seen == other.seen && progress == other.progress
                && chatMessages.count == other.chatMessages.count && suggestions == other.suggestions
                && leadingSuggestion == other.leadingSuggestion
        }
    }

    private(set) var entries: [Entry] = [] {
        didSet {
            guard !streaming else { return }
            pendingChange?.cancel()
            pendingChange = nil
            onChange?(entries)
        }
    }
    /// Streamed words are passed on at most every 0.1 s (an answer streams ~30 chunks a
    /// second); everything else at once.
    private var streaming = false
    private var pendingChange: Task<Void, Never>?
    private static let streamInterval: Duration = .milliseconds(100)
    var onChange: (([Entry]) -> Void)?

    var count: Int { entries.count }
    var hasRoom: Bool { count < AgentDock.maxTiles }

    @discardableResult
    func add(_ job: BackgroundJob, task: Task<Void, Never>?) -> Bool {
        guard hasRoom, !entries.contains(where: { $0.id == job.id }) else { return false }
        entries.insert(Entry(job: job, task: task), at: 0)  // newest on top
        return true
    }

    func append(_ text: String, speech: String = "", to id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        streaming = true
        entries[index].job.append(text)
        entries[index].liveText += speech
        streaming = false
        guard pendingChange == nil else { return }
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: Self.streamInterval)
            guard !Task.isCancelled, let self else { return }
            pendingChange = nil
            onChange?(entries)
        }
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

    func setLeadingSuggestion(_ suggestion: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].leadingSuggestion = suggestion
    }

    func rename(_ id: UUID, to question: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].job.rename(question)
    }

    func setSuggestions(_ suggestions: [String], for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].suggestions = suggestions
    }

    func setHomeWindow(title: String?, frame: Rect?, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].job.homeWindowTitle = title
        entries[index].job.homeWindowFrame = frame
    }

    func setHomeTab(_ tab: BrowserTab?, for id: UUID) {
        guard let tab, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].job.homeTab = tab
    }

    func setSnipMemory(_ memory: AskCoordinator.SnipMemory?, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].snipMemory = memory
    }

    /// A follow-up from the done card's mini-chat: the tile works again on it.
    func reopen(_ id: UUID, asking question: String, task: Task<Void, Never>?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].job.reopen(asking: question)
        entries[index].task = task
        entries[index].liveText = ""
        entries[index].progress = .uncounted
        entries[index].suggestions = nil
        entries[index].leadingSuggestion = nil
        entries[index].seen = false
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
