import Darwin
import Foundation

/// This Mac's memory and disk, for the brain cards: what it has and what's free right now.
/// Read only, nothing leaves the Mac.
enum MachineFacts {
    static var memoryGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    /// Memory an app could have now without the Mac swapping: free, inactive and purgeable pages.
    static var freeMemoryGB: Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = Double(stats.free_count) + Double(stats.inactive_count) + Double(stats.purgeable_count)
        return pages * Double(getpagesize()) / 1_073_741_824
    }

    /// Free space on the startup disk for things the user asked for (macOS may clear caches for it).
    static var freeDiskGB: Double {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Double(values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000
    }
}
