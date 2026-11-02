import ClickBaitCore
import Darwin
import Foundation
import IOKit.ps
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
    private var lastTicks: (busy: UInt64, total: UInt64)?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard enabled(), let cpu = cpuLoad() else { return }
        let (battery, charging) = Self.battery()
        let reading = HealthAlerts.Reading(cpu: cpu, thermal: ProcessInfo.processInfo.thermalState.rawValue,
                                           freeDisk: Self.freeDisk(), battery: battery, charging: charging)
        for kind in alerts.see(reading) {
            let text: String
            switch kind {
            case .cpu: text = "your Mac's been working hard for 2 minutes" + (Self.busiestApp().map { " · mostly \($0)" } ?? "")
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
        let (battery, charging) = Self.battery()
        return "cpu \(cpuLoad().map { String(format: "%.2f", $0) } ?? "first"), thermal \(ProcessInfo.processInfo.thermalState.rawValue), "
            + "disk \(ByteCountFormatter.string(fromByteCount: Self.freeDisk(), countStyle: .file)), battery \(battery.map { String(format: "%.2f", $0) } ?? "none") charging \(charging), busiest \(Self.busiestApp() ?? "?")"
    }
    #endif

    /// All cores' busy share since the last reading (the first reading only sets the start).
    private func cpuLoad() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice, total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return nil }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    private static func freeDisk() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
    }

    /// The internal battery's charge (0…1) and whether it's on power; nil without one.
    private static func battery() -> (Double?, Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in list {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let now = details[kIOPSCurrentCapacityKey] as? Int, let most = details[kIOPSMaxCapacityKey] as? Int, most > 0 else { continue }
            return (Double(now) / Double(most), details[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return (nil, false)
    }

    /// The busiest app right now, by name (`ps`), for the "working hard" pill.
    private static func busiestApp() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pcpu=,comm=", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let first = output.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = first.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }
}
