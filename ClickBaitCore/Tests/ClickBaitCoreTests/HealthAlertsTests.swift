import Foundation
import Testing
@testable import ClickBaitCore

struct HealthAlertsTests {
    let start = Date(timeIntervalSince1970: 0)
    func reading(cpu: Double = 0.2, thermal: Int = 0, disk: Int64 = 100_000_000_000, battery: Double? = 0.8, charging: Bool = false) -> HealthAlerts.Reading {
        .init(cpu: cpu, thermal: thermal, freeDisk: disk, battery: battery, charging: charging)
    }

    @Test func cpuMustStayBusyTwoMinutes() {
        var alerts = HealthAlerts()
        #expect(alerts.see(reading(cpu: 0.9), at: start).isEmpty)
        #expect(alerts.see(reading(cpu: 0.9), at: start + 60).isEmpty)
        #expect(alerts.see(reading(cpu: 0.9), at: start + 121) == [.cpu])
        #expect(alerts.see(reading(cpu: 0.9), at: start + 200).isEmpty)  // said once
        #expect(alerts.see(reading(cpu: 0.7), at: start + 230).isEmpty)  // between: still busy, still quiet
    }

    @Test func saysOnceUntilClearedAndAnHourPassed() {
        var alerts = HealthAlerts()
        #expect(alerts.see(reading(battery: 0.12), at: start) == [.battery])
        #expect(alerts.see(reading(battery: 0.12, charging: true), at: start + 60).isEmpty)  // cleared
        #expect(alerts.see(reading(battery: 0.11), at: start + 120).isEmpty)  // not an hour yet
        #expect(alerts.see(reading(battery: 0.10), at: start + 3700) == [.battery])
        #expect(alerts.see(reading(thermal: 2, disk: 5_000_000_000), at: start).sorted { $0.rawValue < $1.rawValue } == [.disk, .heat])
        #expect(alerts.see(reading(battery: nil), at: start + 9000).isEmpty)  // no battery: never
    }
}
