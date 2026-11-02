import ClickBaitCore
import Darwin
import Foundation
import IOKit
import IOKit.ps
import Observation

/// The Mac's own numbers, read without administrator rights (user's asks, 2026-11-02: health
/// alerts and the Health page): CPU and network as rates between two readings (`Meter`), the
/// rest as they are now.
enum MacStats {
    /// Busy share of all cores and bytes in and out, between this reading and the last.
    struct Meter {
        private var ticks: (busy: UInt64, total: UInt64)?
        private var bytes: (inbound: UInt64, outbound: UInt64, at: Date)?

        mutating func cpu() -> Double? {
            var info = host_cpu_load_info()
            var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
            }
            guard status == KERN_SUCCESS else { return nil }
            let busy = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
            let total = busy + UInt64(info.cpu_ticks.2)
            defer { ticks = (busy, total) }
            guard let last = ticks, total > last.total else { return nil }
            return Double(busy - last.busy) / Double(total - last.total)
        }

        /// Bytes a second down and up, over every interface but loopback.
        mutating func network(now: Date = Date()) -> (down: Double, up: Double)? {
            var list: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&list) == 0, let first = list else { return nil }
            defer { freeifaddrs(list) }
            var inbound: UInt64 = 0, outbound: UInt64 = 0
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let entry = pointer.pointee
                guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                      let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
                inbound += UInt64(data.pointee.ifi_ibytes)
                outbound += UInt64(data.pointee.ifi_obytes)
            }
            defer { bytes = (inbound, outbound, now) }
            guard let last = bytes, now > last.at, inbound >= last.inbound, outbound >= last.outbound else { return nil }
            let seconds = now.timeIntervalSince(last.at)
            return (Double(inbound - last.inbound) / seconds, Double(outbound - last.outbound) / seconds)
        }
    }

    /// The GPU's busy share (the busiest accelerator).
    static func gpu() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var busiest: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any], let used = stats["Device Utilization %"] as? Int {
                busiest = max(busiest ?? 0, Double(used) / 100)
            }
        }
        return busiest
    }

    /// Memory in use (app memory, wired and compressed, as Activity Monitor counts it) and all of it.
    static func memory() -> (used: UInt64, total: UInt64)? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let used = (UInt64(info.internal_page_count) - UInt64(info.purgeable_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }

    /// Free and whole disk (space for important use, as Finder counts it).
    static func disk() -> (free: Int64, total: Int64) {
        let values = try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? .max, Int64(values?.volumeTotalCapacity ?? 0))
    }

    struct Battery {
        var level: Double
        var charging: Bool
        var onPower: Bool
        /// Minutes to empty or full, when macOS knows.
        var minutesLeft: Int?
        var cycles: Int?
        var health: Int?
        /// The whole Mac's draw, and the charger's rating, in watts.
        var draw: Double?
        var charger: Int?
    }

    /// The internal battery, nil without one.
    static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let now = details[kIOPSCurrentCapacityKey] as? Int, let most = details[kIOPSMaxCapacityKey] as? Int, most > 0 else { continue }
            let onPower = details[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = details[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = (charging ? details[kIOPSTimeToFullChargeKey] : details[kIOPSTimeToEmptyKey]) as? Int
            var battery = Battery(level: Double(now) / Double(most), charging: charging, onPower: onPower,
                                  minutesLeft: minutes.flatMap { $0 > 0 ? $0 : nil })
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                var properties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let smart = properties?.takeRetainedValue() as? [String: Any] {
                    battery.cycles = smart["CycleCount"] as? Int
                    // The capacities sit in BatteryData on Apple silicon, at the top on older Macs.
                    let data = smart["BatteryData"] as? [String: Any] ?? [:]
                    let design = smart["DesignCapacity"] as? Int ?? data["DesignCapacity"] as? Int
                    let full = data["NominalChargeCapacity"] as? Int ?? smart["NominalChargeCapacity"] as? Int ?? smart["AppleRawMaxCapacity"] as? Int
                    battery.health = HealthFormat.batteryHealth(full: full, design: design)
                    if let load = (smart["PowerTelemetryData"] as? [String: Any])?["SystemLoad"] as? Int, load > 0 { battery.draw = Double(load) / 1000 }
                    battery.charger = (smart["AdapterDetails"] as? [String: Any])?["Watts"] as? Int
                }
            }
            return battery
        }
        return nil
    }

    /// The busiest process right now, by name (`ps`), for the "working hard" pill.
    static func busiestApp() -> String? {
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

/// The Health page's readings, every 2 s while it shows.
@MainActor @Observable
final class HealthSampler {
    private(set) var cpu: Double?
    private(set) var gpu: Double?
    private(set) var memory: (used: UInt64, total: UInt64)?
    private(set) var battery: MacStats.Battery?
    private(set) var network: (down: Double, up: Double)?
    private(set) var disk = MacStats.disk()
    private(set) var heat = ProcessInfo.processInfo.thermalState.rawValue
    @ObservationIgnored private var meter = MacStats.Meter()

    func sample() {
        cpu = meter.cpu() ?? cpu
        network = meter.network() ?? network
        gpu = MacStats.gpu()
        memory = MacStats.memory()
        battery = MacStats.battery()
        disk = MacStats.disk()
        heat = ProcessInfo.processInfo.thermalState.rawValue
    }
}
