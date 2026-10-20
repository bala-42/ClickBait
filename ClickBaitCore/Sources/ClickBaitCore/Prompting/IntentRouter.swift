import Foundation

/// C3, the checked local brain (LTK's pattern, 2026-10-20): the local model sorts a request
/// into one intent as JSON (Ollama's `format` schema), ClickBait checks the reply, retries once
/// on a bad one, and keeps what passed in a small cache. **Shadow mode for now**: the verdict
/// is only logged next to what ClickBait actually did (`Comparison`), after the answer, and
/// changes nothing. Once its verdicts agree often enough, it can take over one intent at a time.
///
///     var ask = AskRequest(question: "how do I turn on dark mode", screenshotJPEG: Data(), ...)
///     ask.routeIntent = true                       // Prompt.routeSystem + OllamaProvider.routeSchema
///     let reply = ...                              // {"intent": "tutorial", "app": "System Settings"}
///     IntentRouter.parse(reply, apps: installed)   // Route(intent: .tutorial, app: "System Settings")
public enum IntentRouter {
    public enum Intent: String, CaseIterable, Sendable {
        /// A question answered in words (facts, explanations, what's on screen).
        case answer
        /// Where something is on screen: point at it.
        case point
        /// How to do something in an app: walk them through it, step by step.
        case tutorial
        /// Do something now: open or quit an app, a setting, a file action, a note, a reminder.
        case order
        /// It could mean two different things: ask which.
        case clarify
    }

    public struct Route: Equatable, Sendable {
        public var intent: Intent
        /// The app it's about, when the request names one that's installed.
        public var app: String?
    }

    /// The reply, checked: a known intent, and an app only if it's one of `apps` (the closest
    /// installed name; an app that isn't installed is dropped, not invented). Nil when the
    /// reply isn't that shape.
    public static func parse(_ reply: String, apps: [String]) -> Route? {
        guard let data = reply.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["intent"] as? String,
              let intent = Intent(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces)) else { return nil }
        let named = (json["app"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let app = named.isEmpty ? nil : ActionCatalog.bestMatch(for: named, in: apps)
        return Route(intent: intent, app: app)
    }

    /// Verified routes, newest last, at most `capacity`: the same question isn't sorted twice.
    public struct Cache: Sendable {
        public static let capacity = 200
        private var entries: [(key: String, route: Route)] = []

        public init() {}

        public func route(for question: String) -> Route? {
            let key = ImpliedPointer.normalized(question)
            return entries.last { $0.key == key }?.route
        }

        public mutating func store(_ route: Route, for question: String) {
            let key = ImpliedPointer.normalized(question)
            guard !key.isEmpty else { return }
            entries.removeAll { $0.key == key }
            entries.append((key, route))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }

        public var count: Int { entries.count }
    }

    /// The router's verdict next to what ClickBait did, for the log.
    public struct Comparison: Equatable, Sendable {
        public var route: Route?
        public var actual: Intent
        public var agrees: Bool { route?.intent == actual }

        public init(route: Route?, actual: Intent) {
            self.route = route
            self.actual = actual
        }

        /// "said tutorial (System Settings), ClickBait did answer: differs".
        public var summary: String {
            guard let route else { return "no valid verdict, ClickBait did \(actual.rawValue)" }
            let app = route.app.map { " (\($0))" } ?? ""
            return "said \(route.intent.rawValue)\(app), ClickBait did \(actual.rawValue): \(agrees ? "agrees" : "differs")"
        }
    }
}
