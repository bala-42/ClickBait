import AppKit
import ClickBaitCore
import EventKit

/// The morning greeting (`MorningCards` in Core holds the rules): with Settings → General →
/// Morning suggestions on, once a day on the first launch or wake after 5 am, reads today's
/// reminders and events (only if allowed) and the remembered facts, has the local model write
/// two or three warm sentences — by name, only what matters — and hands them to `present`, which
/// types them out in the notch (user's ask, 2026-11-02; it was cards in the dock). Without the
/// model, a plain greeting from the same facts. Text only, local only.
@MainActor
final class MorningBrief {
    private let settings: AppSettings
    /// Shows the greeting (the notch); false when it couldn't now (try on the next wake).
    var present: (String) -> Bool = { _ in false }
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

    /// `force`: now, whatever the day (a live test).
    func check(force: Bool = false) async {
        guard force || settings.morningCards, !running,
              force || MorningCards.isDue(now: Date(), lastShown: settings.morningCardsShown) else { return }
        running = true
        defer { running = false }
        let name = NSFullUserName().split(separator: " ").first.map(String.init)
        let facts = MemoryStore.shared.memory.notes.suffix(10).reversed().map(\.text)
        let (reminders, events) = await Self.todayItems()
        var text = MorningCards.plainGreeting(name: name, reminders: reminders, events: events, now: Date())
        if let brief = MorningCards.brief(reminders: reminders, events: events, facts: facts, now: Date(), name: name) {
            var ask = AskRequest(question: "Good morning", screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                                 context: ScreenContext(appName: nil), selectedText: nil)
            ask.morningBrief = brief
            // Ollama may be loading the model after a wake: allow it a while, then the plain one.
            let reply = await AskCoordinator.reply(from: settings.makeProvider(), to: ask, within: .seconds(30))
            if let written = reply.flatMap(MorningCards.greeting) { text = written }
        }
        if present(text) { settings.morningCardsShown = Date() }
        Log.app.notice("Morning greeting: \(text.count, privacy: .public) characters")
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
    /// These EventKit callbacks may run off-main. Keep the whole EventKit read in nonisolated
    /// helpers so their completion closures do not inherit MorningBrief's MainActor isolation.
    nonisolated private static func todayItems() async -> (reminders: [MorningCards.Item], events: [MorningCards.Item]) {
        let store = EKEventStore()
        let reminders = await reminders(in: store)
        let events = events(in: store)
        return (reminders, events)
    }

    nonisolated private static func reminders(in store: EKEventStore) async -> [MorningCards.Item] {
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
    nonisolated private static func events(in store: EKEventStore) -> [MorningCards.Item] {
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
