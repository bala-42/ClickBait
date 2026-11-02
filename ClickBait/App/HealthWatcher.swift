import ClickBaitCore
import Foundation
import OSLog

/// Mac health by the cursor (user's choice, 2026-11-02, after Vorssaint's alerts): every 30 s,
/// the CPU's load, macOS's thermal state, free disk and the battery, judged by `HealthAlerts`.
/// Read on this Mac; nothing is kept.
@MainActor
final class HealthWatcher {
    var enabled: () -> Bool = { true }
    var say: (String) -> Void = { _ in }
    private var alerts = HealthAlerts()
    private var timer: Timer?
    private var meter = MacStats.Meter()

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard enabled(), let cpu = meter.cpu() else { return }
        let battery = MacStats.battery()
        let reading = HealthAlerts.Reading(cpu: cpu, thermal: ProcessInfo.processInfo.thermalState.rawValue,
                                           freeDisk: MacStats.disk().free, battery: battery?.level, charging: battery?.onPower ?? false)
        for kind in alerts.see(reading) {
            let text: String
            switch kind {
            case .cpu: text = "your Mac's been working hard for 2 minutes" + (MacStats.busiestApp().map { " · mostly \($0)" } ?? "")
            case .heat: text = "your Mac is running hot — give it a moment"
            case .disk: text = "only \(ByteCountFormatter.string(fromByteCount: reading.freeDisk, countStyle: .file)) of disk left"
            case .battery: text = "battery at \(Int((reading.battery ?? 0) * 100))% — time to plug in"
            }
            Log.app.notice("Health: \(kind.rawValue, privacy: .public)")
            say(text)
        }
    }

    #if DEBUG
    /// One reading, as text (`org.clickbait.debug.health`).
    func describeNow() -> String {
        let battery = MacStats.battery()
        let memory = MacStats.memory()
        return "cpu \(meter.cpu().map { String(format: "%.2f", $0) } ?? "first"), gpu \(MacStats.gpu().map { String(format: "%.2f", $0) } ?? "?"), "
            + "memory \(memory.map { "\($0.used / 1_000_000_000)/\($0.total / 1_000_000_000) GB" } ?? "?"), thermal \(ProcessInfo.processInfo.thermalState.rawValue), "
            + "disk \(ByteCountFormatter.string(fromByteCount: MacStats.disk().free, countStyle: .file)), battery \(battery.map { String(format: "%.2f", $0.level) } ?? "none") "
            + "power \(battery?.onPower ?? false) cycles \(battery?.cycles ?? -1) health \(battery?.health ?? -1)% draw \(battery?.draw ?? -1) W charger \(battery?.charger ?? -1) W, busiest \(MacStats.busiestApp() ?? "?")"
    }
    #endif
}
