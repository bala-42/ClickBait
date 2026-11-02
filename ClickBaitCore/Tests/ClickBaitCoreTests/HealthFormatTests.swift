import Testing
@testable import ClickBaitCore

struct HealthFormatTests {
    @Test func words() {
        #expect(HealthFormat.rate(92_400) == "92 KB/s")
        #expect(HealthFormat.rate(2_300_000) == "2.3 MB/s")
        #expect(HealthFormat.rate(-5) == "0 KB/s")
        #expect(HealthFormat.batteryHealth(full: 5621, design: 6249) == 90)
        #expect(HealthFormat.batteryHealth(full: nil, design: 6249) == nil)
        #expect(HealthFormat.heat(0) == "cool" && HealthFormat.heat(3) == "very hot")
    }
}
