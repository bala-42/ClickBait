#if DEBUG
import AppKit
import ClickBaitCore

/// A repeatable run of the companion's busiest states, for profiling (Debug builds only).
/// Launch with `CLICKBAIT_BENCH=1` and keep the mouse still in a corner; each phase is
/// logged ("Bench: …") so stalls and samples can be matched to it.
extension OverlayController {
    func runBenchmarkIfRequested() {
        guard ProcessInfo.processInfo.environment["CLICKBAIT_BENCH"] != nil,
              let screen = NSScreen.main?.frame else { return }
        // CLICKBAIT_BENCH=esc: a real Esc posted through the system while idle (it must pass
        // to the app in front) and while spinning (it must be taken and end the spin).
        let postsEsc = ProcessInfo.processInfo.environment["CLICKBAIT_BENCH"] == "esc"
        func postEsc() {
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
                usleep(30_000)  // a real press: down, then up
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if postsEsc { Log.app.notice("Bench: Esc while idle"); postEsc(); try? await Task.sleep(for: .seconds(0.5)) }
            Log.app.notice("Bench: spin")
            show(.thinking)
            if postsEsc {
                try? await Task.sleep(for: .seconds(2))
                Log.app.notice("Bench: Esc while spinning")
                postEsc()
                try? await Task.sleep(for: .seconds(0.5))
                Log.app.notice("Bench: after Esc, bubble \(String(describing: self.model.bubble), privacy: .public), spinning \(self.model.isSpinning, privacy: .public)")
                return
            }
            try? await Task.sleep(for: .seconds(6))
            show(.idle)
            // Six stops around the middle of the main screen, a 2.4 s tour each.
            let stops = (0..<6).map { index in
                let angle = Double(index) * .pi / 3
                let x = screen.midX + 320 * cos(angle), y = screen.midY + 220 * sin(angle)
                return ScreenPointer(label: "part \(index + 1)", appKit: Point(x: x, y: y),
                                     quartz: Point(x: x, y: screen.maxY - y))
            }
            Log.app.notice("Bench: tour")
            tour(stops)
            // Six parts, each a flight plus 2.4 s held from arrival.
            try? await Task.sleep(for: .seconds(20))
            Log.app.notice("Bench: point")
            guide(to: [stops[3]], label: "this one!")
            // A flight, 3 s held from arrival, and the flight home.
            try? await Task.sleep(for: .seconds(5.5))
            Log.app.notice("Bench: done")
        }
    }
}
#endif
