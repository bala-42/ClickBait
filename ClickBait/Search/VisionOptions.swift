import Foundation
import IOKit.ps
import os

/// Vision Memory's settings as `SearchIndex` sees them (a copy, read on the main actor).
struct VisionOptions: Sendable {
    var photos: Bool
    var brain: String
    var describe: Bool
    var pausedUntil: Date?
    var folders: [String]
    var excluded: [String]
    var screenshots: Bool
    var onBattery: Bool

    var isPaused: Bool { !describe || (pausedUntil.map { $0 > Date() } ?? false) }

    /// Pictures may be read and described right now: not paused, not while the user is asking
    /// ClickBait, not in Low Power Mode or when the Mac is hot, not on battery unless allowed.
    var mayWork: Bool {
        guard !isPaused, !AskActivity.isBusy, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return false
        default: break
        }
        return onBattery || !Self.onBatteryPower
    }

    static var onBatteryPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPMBatteryPowerKey
    }
}

/// Whether an ask is under way (set from `AskCoordinator.state`), so background work waits.
enum AskActivity {
    private static let busy = OSAllocatedUnfairLock(initialState: false)
    static var isBusy: Bool { busy.withLock { $0 } }
    static func set(_ value: Bool) { busy.withLock { $0 = value } }
}
