import AppKit
import ClickBaitCore
import EventKit
import OSLog

/// Next Up (user's choice, 2026-11-02): every 30 s, today's calendar events (only if calendar
/// access was already given — the morning greeting asks); five minutes before one starts, a card
/// by the cursor with its call link (`NextUp`). Each event once.
@MainActor
final class NextUpWatcher {
    /// Shows the card: (what it says, the button's word, what the button does).
    var show: (String, String, @escaping () -> Void) -> Void = { _, _, _ in }
    private var told: Set<String> = []
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check(now: Date = Date()) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let event = NextUp.due(Self.upcoming(now: now), now: now, told: told) else { return }
        told.insert(event.id)
        let minutes = max(0, Int((event.start.timeIntervalSince(now) / 60).rounded()))
        let time = event.start.formatted(date: .omitted, time: .shortened)
        let text = "next up: \(event.title) at \(time)" + (minutes > 0 ? " · in \(minutes) min" : " · now")
        Log.app.notice("Next up: in \(minutes, privacy: .public) min, \(NextUp.link(in: event.places) == nil ? "no link" : "with a link", privacy: .public)")
        if let link = NextUp.link(in: event.places) {
            show(text, "join") { NSWorkspace.shared.open(link) }
        } else {
            show(text, "open") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) }
        }
    }

    #if DEBUG
    /// Access, and what's in the next ten minutes (`org.clickbait.debug.nextup`).
    func describeNow() -> String {
        let status = EKEventStore.authorizationStatus(for: .event)
        let soon = status == .fullAccess ? Self.upcoming(now: Date()) : []
        return "calendar access \(status == .fullAccess ? "full" : "\(status.rawValue)"), \(soon.count) event(s) in 10 min, \(soon.filter { NextUp.link(in: $0.places) != nil }.count) with a call link"
    }
    #endif

    /// Timed events in the next ten minutes (not all-day, not declined).
    nonisolated private static func upcoming(now: Date) -> [NextUp.Event] {
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-60), end: now.addingTimeInterval(600), calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, event.status != .canceled,
                  !(event.attendees ?? []).contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) else { return nil }
            let places = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
            return NextUp.Event(id: (event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString) + "\(event.startDate.timeIntervalSince1970)",
                                title: event.title ?? "a meeting", start: event.startDate, places: places)
        }
    }
}
