#if DEBUG
import Darwin
import Foundation

/// Debug builds only: catches what the main thread is doing when it freezes (the companion
/// stalled up to 2.5 s while idle, 2026-10-23, and the logs only said when). A watchdog
/// thread pings the main queue every `interval`; when a ping is still waiting past
/// `threshold`, it pauses the main thread for a moment, walks its frame pointers, and logs
/// each frame as image+offset (symbolize offline with `atos`). Once per freeze.
final class StallTrap: @unchecked Sendable {
    static let shared = StallTrap()

    private let threshold: TimeInterval = Double(ProcessInfo.processInfo.environment["CLICKBAIT_STALL_MS"] ?? "").map { $0 / 1000 } ?? 0.1
    private let interval: TimeInterval = 0.05
    private var mainPort: mach_port_t = 0
    private var stackBounds: ClosedRange<UInt> = 0...0
    private let lock = NSLock()
    private var answered = true
    private var askedAt = Date()

    /// Call on the main thread.
    func start() {
        mainPort = mach_thread_self()
        let thread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        stackBounds = (top - UInt(pthread_get_stacksize_np(thread)))...top
        let watchdog = Thread { [self] in watch() }
        watchdog.name = "ClickBait stall trap"
        watchdog.qualityOfService = .utility
        watchdog.start()
        Log.app.notice("Stall trap: watching the main thread (freezes over \(Int(self.threshold * 1000), privacy: .public) ms)")
    }

    private func watch() {
        var reported = false
        while true {
            Thread.sleep(forTimeInterval: interval)
            lock.lock()
            let waiting = !answered
            let since = Date().timeIntervalSince(askedAt)
            if !waiting {
                answered = false
                askedAt = Date()
                reported = false
            }
            lock.unlock()
            if !waiting {
                DispatchQueue.main.async { [self] in
                    lock.lock()
                    answered = true
                    lock.unlock()
                }
            } else if since > threshold, !reported {
                reported = true
                let frames = mainStack()
                Log.app.notice("Stall trap: main thread stuck \(Int(since * 1000), privacy: .public) ms at: \(frames.joined(separator: " | "), privacy: .public)")
            }
        }
    }

    /// The main thread's return addresses, as "image+0xoffset (symbol)".
    private func mainStack() -> [String] {
        var addresses: [UInt] = []
        guard thread_suspend(mainPort) == KERN_SUCCESS else { return ["(couldn't pause)"] }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let got = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainPort, ARM_THREAD_STATE64, $0, &count)
            }
        }
        if got == KERN_SUCCESS {
            addresses.append(UInt(state.__pc))
            addresses.append(UInt(state.__lr))
            var fp = UInt(state.__fp)
            // Each frame: [previous fp, return address]; only within the main stack.
            while addresses.count < 48, fp & 0xF == 0, stackBounds.contains(fp), stackBounds.contains(fp + 16) {
                let frame = UnsafePointer<UInt>(bitPattern: fp)!
                let next = frame[0]
                addresses.append(frame[1])
                guard next > fp else { break }
                fp = next
            }
        }
        thread_resume(mainPort)
        // Strip pointer-authentication bits, then name each address (after resuming).
        return addresses.map { $0 & 0x0000_007F_FFFF_FFFF }.filter { $0 > 0x1000 }.map(Self.describe)
    }

    private static func describe(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let base = info.dli_fbase else {
            return String(format: "0x%lx", address)
        }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        let offset = address - UInt(bitPattern: base)
        let symbol = info.dli_sname.map { String(cString: $0) }.map { " " + $0.prefix(80) } ?? ""
        return "\(image)+0x\(String(offset, radix: 16))\(symbol)"
    }
}
#endif
