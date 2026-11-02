import Foundation

/// Next Up (user's choice, 2026-11-02, after Pulsar's and Vorssaint's): a meeting five minutes
/// before it starts, with its call link to join. Pure: which event is due, and its link.
public enum NextUp {
    public struct Event: Equatable, Sendable {
        public let id: String
        public let title: String
        public let start: Date
        /// Where a call link may be: the event's URL, location and notes.
        public let places: [String]
        public init(id: String, title: String, start: Date, places: [String]) {
            (self.id, self.title, self.start, self.places) = (id, title, start, places)
        }
    }

    public static let ahead: TimeInterval = 5 * 60

    /// The soonest event starting within five minutes (and not yet begun a minute ago) that
    /// hasn't been told yet.
    public static func due(_ events: [Event], now: Date, told: Set<String>) -> Event? {
        events.filter { !told.contains($0.id) && $0.start.timeIntervalSince(now) <= ahead && $0.start.timeIntervalSince(now) > -60 }
            .min { $0.start < $1.start }
    }

    /// The first call link: Zoom, Google Meet, Teams, Webex or FaceTime.
    public static func link(in places: [String]) -> URL? {
        let pattern = #"https://([a-z0-9-]+\.)*(zoom\.us/(j|my|w)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join/|teams\.live\.com/meet/|[a-z0-9-]+\.webex\.com/|facetime\.apple\.com/join)[^\s<>"')]*"#
        for place in places {
            if let range = place.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { return URL(string: String(place[range])) }
        }
        return nil
    }
}
