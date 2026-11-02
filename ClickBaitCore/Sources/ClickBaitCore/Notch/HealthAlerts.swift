import Foundation

/// Mac health, said by the cursor (user's choice, 2026-11-02, after Vorssaint's alerts): the
/// CPU working hard for two minutes, serious heat, low disk, low battery. Each says once, then
/// waits until it has cleared (with some room, so it doesn't flicker) and an hour has passed.
public struct HealthAlerts: Sendable {
    public enum Kind: String, Sendable, CaseIterable { case cpu, heat, disk, battery }

    public struct Reading: Sendable {
        /// All cores together, 0…1.
        public var cpu: Double
        /// macOS's thermal state: 0 nominal, 1 fair, 2 serious, 3 critical.
        public var thermal: Int
        public var freeDisk: Int64
        /// 0…1, nil without a battery.
        public var battery: Double?
        public var charging: Bool
        public init(cpu: Double, thermal: Int, freeDisk: Int64, battery: Double?, charging: Bool) {
            (self.cpu, self.thermal, self.freeDisk, self.battery, self.charging) = (cpu, thermal, freeDisk, battery, charging)
        }
    }

    public static let busy = 0.85, calm = 0.6
    public static let busyFor: TimeInterval = 120
    public static let lowDisk: Int64 = 10_000_000_000, roomyDisk: Int64 = 15_000_000_000
    public static let lowBattery = 0.15, okBattery = 0.2
    public static let quietFor: TimeInterval = 3600

    private var busySince: Date?
    private var raised: Set<Kind> = []
    private var said: [Kind: Date] = [:]

    public init() {}

    /// A new reading: the alerts to say now.
    public mutating func see(_ reading: Reading, at now: Date = Date()) -> [Kind] {
        if reading.cpu >= Self.busy { busySince = busySince ?? now } else if reading.cpu < Self.calm { busySince = nil }
        let on: [Kind: Bool] = [
            .cpu: busySince.map { now.timeIntervalSince($0) >= Self.busyFor } ?? false,
            .heat: reading.thermal >= 2,
            .disk: reading.freeDisk < Self.lowDisk,
            .battery: reading.battery.map { $0 <= Self.lowBattery && !reading.charging } ?? false,
        ]
        let cleared: [Kind: Bool] = [
            .cpu: busySince == nil,
            .heat: reading.thermal <= 1,
            .disk: reading.freeDisk > Self.roomyDisk,
            .battery: reading.battery.map { $0 >= Self.okBattery || reading.charging } ?? true,
        ]
        var now_: [Kind] = []
        for kind in Kind.allCases {
            if raised.contains(kind) {
                if cleared[kind] == true { raised.remove(kind) }
            } else if on[kind] == true, said[kind].map({ now.timeIntervalSince($0) >= Self.quietFor }) ?? true {
                raised.insert(kind)
                said[kind] = now
                now_.append(kind)
            }
        }
        return now_
    }
}
