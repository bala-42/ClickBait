import AppKit
import ClickBaitCore
import EventKit

/// Morning cards (`MorningCards` in Core holds the rules): with Settings → General → Morning
/// suggestions on, once a day on the first launch or wake after 5 am, reads today's reminders
/// and events (only if allowed) and the remembered facts, asks the local model for up to three
/// things to ask, and hands them to `present`, which shows them as a done card in the dock.
/// Nothing runs until a card is tapped. Text only, local only. Idea from Sentient OS.
@MainActor
final class MorningBrief {
    private let settings: AppSettings
    /// (the day's summary, the cards): false if the dock had no room.
    var present: (String, [String]) -> Bool = { _, _ in false }
    private var observer: NSObjectProtocol?
    private var running = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSoon() }
        }
        checkSoon()
    }

    /// A moment after launch or wake, so Ollama and the network settle first.
    private func checkSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            await self?.check()
        }
    }

    private func check() async {
        guard settings.morningCards, !running,
              MorningCards.isDue(now: Date(), lastShown: settings.morningCardsShown) else { return }
        running = true
        defer { running = false }
        let store = EKEventStore()
        let facts = MemoryStore.shared.memory.notes.suffix(10).reversed().map(\.text)
        let reminders = await Self.reminders(in: store)
        let events = Self.events(in: store)
        guard let brief = MorningCards.brief(reminders: reminders, events: events, facts: facts, now: Date()) else {
            Log.app.notice("Morning cards: nothing to go on today")
            settings.morningCardsShown = Date()
            return
        }
        var ask = AskRequest(question: "Good morning", screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                             context: ScreenContext(appName: nil), selectedText: nil)
        ask.morningBrief = brief
        // Ollama may be loading the model after a wake: allow it a while.
        let reply = await AskCoordinator.reply(from: settings.makeProvider(), to: ask, within: .seconds(60))
        guard let cards = reply.flatMap(MorningCards.parse), !cards.isEmpty else {
            Log.app.notice("Morning cards: no usable reply; trying again on the next wake")
            return
        }
        if present(brief, cards) { settings.morningCardsShown = Date() }
        Log.app.notice("Morning cards: \(cards.count, privacy: .public)")
    }

    /// Asked when the setting is turned on. Either may be refused; the cards then use what's left.
    static func requestAccess() {
        let store = EKEventStore()
        Task {
            _ = try? await store.requestFullAccessToReminders()
            _ = try? await store.requestFullAccessToEvents()
        }
    }

    /// Incomplete reminders due by the end of today, if allowed.
    private static func reminders(in store: EKEventStore) async -> [MorningCards.Item] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                let items = (found ?? []).map { reminder in
                    MorningCards.Item(title: reminder.title ?? "", time: reminder.dueDateComponents?.date)
                }
                continuation.resume(returning: items.filter { !$0.title.isEmpty })
            }
        }
    }

    /// Today's events, in order, if allowed; all-day ones without a time.
    private static func events(in store: EKEventStore) -> [MorningCards.Item] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .compactMap { event in
                guard let title = event.title, !title.isEmpty else { return nil }
                return MorningCards.Item(title: title, time: event.isAllDay ? nil : event.startDate)
            }
    }
}
