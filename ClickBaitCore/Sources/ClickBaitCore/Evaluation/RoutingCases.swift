/// Questions labelled with the help they should get, for measuring how ClickBait sorts
/// requests (the rules in `RoutingCasesTests`, the local model in the app's
/// `CLICKBAIT_ROUTE_BENCH`). Written to match how this Mac is used: browsers, YouTube,
/// Finder, System Settings, notes, code. Add a case whenever a real request is sorted wrong.
public enum RoutingCases {
    public struct Case: Sendable {
        public let question: String
        public let expected: IntentRouter.Intent
    }

    public static let all: [Case] = [
        // Where something is: point.
        .init(question: "where's the share button", expected: .point),
        .init(question: "where is the download button on this page", expected: .point),
        .init(question: "show me the refresh button", expected: .point),
        .init(question: "where are the back and forward buttons", expected: .point),
        .init(question: "point at the search bar", expected: .point),
        .init(question: "where's the subscribe button", expected: .point),
        .init(question: "which button closes this window", expected: .point),
        .init(question: "where do I click to log in", expected: .point),
        .init(question: "where's the settings icon", expected: .point),
        .init(question: "find the reply button", expected: .point),
        // "Show me how to …" is a walkthrough; "show me the …" points (user's decision, 2026-10-24).
        .init(question: "show me how to turn on night shift", expected: .tutorial),
        .init(question: "show me how to open an incognito window in chrome", expected: .tutorial),
        .init(question: "show me the share button", expected: .point),
        // How to do something: a walkthrough.
        .init(question: "how do I clear my history in safari", expected: .tutorial),
        .init(question: "how do I change my wallpaper", expected: .tutorial),
        .init(question: "how do I show hidden files in finder", expected: .tutorial),
        .init(question: "walk me through exporting this as a pdf", expected: .tutorial),
        .init(question: "how do I add a printer", expected: .tutorial),
        .init(question: "how do I turn on do not disturb", expected: .tutorial),
        .init(question: "how do I make a new folder", expected: .tutorial),
        .init(question: "how do I change the default search engine in safari", expected: .tutorial),
        .init(question: "how do I connect to a server in finder", expected: .tutorial),
        .init(question: "teach me how to take a screenshot", expected: .tutorial),
        .init(question: "how do I force quit an app", expected: .tutorial),
        .init(question: "how do I install a chrome extension", expected: .tutorial),
        .init(question: "how do I empty the bin", expected: .tutorial),
        // Do it now: an order.
        .init(question: "open notes", expected: .order),
        .init(question: "quit spotify", expected: .order),
        .init(question: "open my downloads folder", expected: .order),
        .init(question: "make a note of this", expected: .order),
        .init(question: "remind me to call mum at 6", expected: .order),
        .init(question: "open calendar", expected: .order),
        .init(question: "launch xcode", expected: .order),
        .init(question: "hide all windows", expected: .order),
        .init(question: "open system settings", expected: .order),
        .init(question: "add this to my notes", expected: .order),
        // A question to answer in words.
        .init(question: "what does this error mean", expected: .answer),
        .init(question: "summarise this page", expected: .answer),
        .init(question: "explain this code", expected: .answer),
        .init(question: "why is my mac so slow", expected: .answer),
        .init(question: "what is this website about", expected: .answer),
        .init(question: "translate this to english", expected: .answer),
        .init(question: "is this email a scam", expected: .answer),
        .init(question: "what's the difference between these two options", expected: .answer),
        .init(question: "write a reply to this message", expected: .answer),
        .init(question: "how do I make this code faster", expected: .answer),
        .init(question: "what time is it in london", expected: .answer),
        .init(question: "who made this video", expected: .answer),
        .init(question: "write a snake game in python", expected: .answer),
        .init(question: "what does this button do", expected: .answer),
        .init(question: "how many calories are in a banana", expected: .answer),
    ]
}
