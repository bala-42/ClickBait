import Testing
@testable import ClickBaitCore

struct HeadphoneGuardTests {
    @Test func turnsDownOnlyFromHeadphonesToSpeakers() {
        #expect(HeadphoneGuard.volume(after: 0.8, from: .headphones, to: .speakers) == 0.25)
        #expect(HeadphoneGuard.volume(after: 0.1, from: .headphones, to: .speakers) == nil)  // already quiet
        #expect(HeadphoneGuard.volume(after: 0.8, from: .speakers, to: .headphones) == nil)
        #expect(HeadphoneGuard.volume(after: 0.8, from: .other, to: .speakers) == nil)  // a display's speakers
        #expect(HeadphoneGuard.kind(transport: "blue", dataSource: nil) == .headphones)
        #expect(HeadphoneGuard.kind(transport: "bltn", dataSource: "hdpn") == .headphones)
        #expect(HeadphoneGuard.kind(transport: "bltn", dataSource: "ispk") == .speakers)
        #expect(HeadphoneGuard.kind(transport: "hdmi", dataSource: nil) == .other)
    }
}
