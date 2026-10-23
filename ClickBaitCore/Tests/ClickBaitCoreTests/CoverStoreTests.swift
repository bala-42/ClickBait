import Foundation
import Testing
@testable import ClickBaitCore

struct CoverStoreTests {
    @Test func namesAreStableSafeAndHideTheTrack() {
        let name = CoverStore.fileName(for: "com.spotify.client|Hukum|Anirudh")
        #expect(name == CoverStore.fileName(for: "com.spotify.client|Hukum|Anirudh"))
        #expect(name != CoverStore.fileName(for: "youtube|dQw4w9WgXcQ"))
        #expect(!name.contains("Hukum") && !name.contains("/"))
        #expect(name.hasSuffix(".cover") && name.count == 64 + 6)
    }

    @Test func dropsTheLeastRecentlyUsedPastTheLimit() {
        let now = Date()
        let files = (0..<5).map { (name: "f\($0)", used: now.addingTimeInterval(Double($0))) }
        #expect(CoverStore.overflow(files, limit: 3) == ["f0", "f1"])
        #expect(CoverStore.overflow(files, limit: 5).isEmpty)
    }
}
