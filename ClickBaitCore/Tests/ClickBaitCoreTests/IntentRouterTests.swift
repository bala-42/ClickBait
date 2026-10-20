import Foundation
import Testing
@testable import ClickBaitCore

/// C3 in shadow mode: the router's reply checked, cached, and compared with what ClickBait did.
struct IntentRouterTests {
    private let apps = ["Safari", "Notes", "System Settings", "Mail"]

    @Test func aGoodReplyParses() {
        #expect(IntentRouter.parse(#"{"intent": "tutorial", "app": "System Settings"}"#, apps: apps)
            == IntentRouter.Route(intent: .tutorial, app: "System Settings"))
        #expect(IntentRouter.parse(#"{"intent": "answer", "app": ""}"#, apps: apps) == IntentRouter.Route(intent: .answer, app: nil))
    }

    @Test func appsAreMatchedToInstalledOnesNeverInvented() {
        #expect(IntentRouter.parse(#"{"intent": "order", "app": "safari"}"#, apps: apps)?.app == "Safari")
        #expect(IntentRouter.parse(#"{"intent": "order", "app": "Photoshop"}"#, apps: apps)?.app == nil)
    }

    @Test func badRepliesAreRejected() {
        #expect(IntentRouter.parse(#"{"intent": "dance", "app": ""}"#, apps: apps) == nil)
        #expect(IntentRouter.parse("tutorial", apps: apps) == nil)
        #expect(IntentRouter.parse(#"{"app": "Safari"}"#, apps: apps) == nil)
    }

    @Test func theCacheKeepsTheNewestAndStaysSmall() {
        var cache = IntentRouter.Cache()
        cache.store(.init(intent: .answer, app: nil), for: "Why is the sky blue?")
        #expect(cache.route(for: "why is the sky blue") == .init(intent: .answer, app: nil))
        cache.store(.init(intent: .point, app: nil), for: "why is the sky blue")
        #expect(cache.route(for: "Why is the sky blue?")?.intent == .point)
        for i in 0..<(IntentRouter.Cache.capacity + 10) { cache.store(.init(intent: .answer, app: nil), for: "q \(i)") }
        #expect(cache.count == IntentRouter.Cache.capacity)
        #expect(cache.route(for: "q 0") == nil)
    }

    @Test func comparisonsReadPlainly() {
        let agree = IntentRouter.Comparison(route: .init(intent: .order, app: "Notes"), actual: .order)
        #expect(agree.agrees && agree.summary == "said order (Notes), ClickBait did order: agrees")
        let differ = IntentRouter.Comparison(route: .init(intent: .tutorial, app: nil), actual: .answer)
        #expect(!differ.agrees && differ.summary == "said tutorial, ClickBait did answer: differs")
        #expect(IntentRouter.Comparison(route: nil, actual: .point).summary == "no valid verdict, ClickBait did point")
    }

    @Test func theRouteRequestIsTextOnlyWithItsOwnPromptAndShape() {
        var ask = AskRequest(question: "how do I turn on dark mode", screenshotJPEG: Data(), screenshotWidth: 0,
                             screenshotHeight: 0, context: ScreenContext(appName: "Finder"))
        ask.routeIntent = true
        #expect(Prompt.system(for: ask) == Prompt.routeSystem)
        #expect(Prompt.userText(for: ask) == "Frontmost app: Finder\nRequest: how do I turn on dark mode")
        let body = OllamaProvider.chatBody(for: ask, model: "qwen3.5:9b")
        let format = body["format"] as? [String: Any]
        let intent = (format?["properties"] as? [String: Any])?["intent"] as? [String: Any]
        #expect(intent?["enum"] as? [String] == ["answer", "point", "tutorial", "order", "clarify"])
        #expect((body["options"] as? [String: Any])?["num_predict"] as? Int == 40)
        #expect(body["messages"].map { ($0 as? [[String: Any]])?.last?["images"] == nil } == true)
    }
}
