#if DEBUG
import AppKit

/// Every Debug self-test switch in one place (idea from Sentient OS's self-test dispatcher).
/// Each is an environment variable read at launch; `CLICKBAIT_SELFTEST=list` prints them all
/// and quits. The ones that run and quit go first, before ClickBait quits other copies of
/// itself or starts anything (`runBeforeLaunch`); the rest run inside a normal launch. Launch
/// with `open -n --env NAME=value ClickBait.app` so ClickBait's own permissions apply.
enum SelfTest: String, CaseIterable {
    // Run, then quit; launch side effects are skipped.
    case renderDock = "CLICKBAIT_RENDER_DOCK"
    case renderChat = "CLICKBAIT_RENDER_CHAT"
    case tourBench = "CLICKBAIT_TOUR_BENCH"
    case askBench = "CLICKBAIT_ASK_BENCH"
    // Run inside a normal launch.
    case greeting = "CLICKBAIT_TEST_GREETING"
    case notch = "CLICKBAIT_TEST_NOTCH"
    case overlayBench = "CLICKBAIT_BENCH"
    case chatBench = "CLICKBAIT_BENCH_CHAT"
    case dockBench = "CLICKBAIT_BENCH_DOCK"
    case cardVoice = "CLICKBAIT_TEST_CARD_VOICE"
    case notchVoice = "CLICKBAIT_TEST_NOTCH_VOICE"
    case routeBench = "CLICKBAIT_ROUTE_BENCH"
    case goThere = "CLICKBAIT_TEST_GOTHERE"
    case guidance = "CLICKBAIT_TEST_GUIDANCE"
    case tourSteps = "CLICKBAIT_TOUR_STEPS"

    var summary: String {
        switch self {
        case .renderDock: "folder: render the agent dock to PNGs"
        case .renderChat: "folder: render the chat to PNGs (CLICKBAIT_RENDER_TAG names them)"
        case .tourBench: "boxes file: benchmark parts tours (CLICKBAIT_TOUR_BENCH_OUT, _RUNS, _ONLY)"
        case .askBench: "sizes, e.g. 1280,896: benchmark screen answers (CLICKBAIT_ASK_BENCH_OUT, CLICKBAIT_ASK_RUNS)"
        case .greeting: "show the companion's greeting after 2 s"
        case .notch: "hover, open and close the notch, logging each (CLICKBAIT_TEST_NOTCH_HUD, _RENDER folder)"
        case .overlayBench: "the companion's busiest states, phase by phase, for profiling (\"esc\" posts Esc too)"
        case .chatBench: "stream a canned answer into an open chat, no model"
        case .dockBench: "the background dock with no model: tiles, a streaming card, then peels"
        case .cardVoice: "a done card's voice button: records ~1.5 s, then pressed twice fast (no model)"
        case .routeBench: "the local model sorts every labelled question (RoutingCases); logs accuracy and misses (uses the model)"
        case .notchVoice: "the notch Ask card's voice: start, stop, dictation taking over, Esc; logs PASS/FAIL (no model)"
        case .goThere: "Chrome pid: \"go there!\" to a hidden tab, then checks it is focused and showing"
        case .guidance: "a labelled highlight and an armed arrow, checked end to end (=folder also renders it)"
        case .tourSteps: "which parts-tour steps are on (A, C, D, E), for the tour benchmark"
        }
    }

    /// The switches set for this launch.
    static var requested: [SelfTest] {
        let environment = ProcessInfo.processInfo.environment
        return allCases.filter { environment[$0.rawValue] != nil }
    }

    /// Runs a test that quits when it's done; true when one started (the launch stops there).
    /// `list` prints every switch and quits.
    @MainActor
    static func runBeforeLaunch(settings: AppSettings) -> Bool {
        if ProcessInfo.processInfo.environment["CLICKBAIT_SELFTEST"] == "list" {
            let list = allCases.map { "\($0.rawValue)  \($0.summary)" }.joined(separator: "\n") + "\n"
            FileHandle.standardOutput.write(Data(list.utf8))  // unbuffered: the app quits next
            NSApp.terminate(nil)
            return true
        }
        if !requested.isEmpty {
            Log.app.notice("Self-test: \(requested.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        }
        AgentDockRender.runIfRequested()  // renders and quits
        ChatRender.runIfRequested()  // renders and quits; leaves a running ClickBait alone
        if TourBench.runIfRequested(settings: settings) { return true }  // benchmarks tours, then quits
        return AskBench.runIfRequested(settings: settings)  // benchmarks screen answers, then quits
    }
}
#endif
