import Testing
@testable import ClickBaitCore

struct AppLeftoversTests {
    @Test func placesAndSafety() {
        let places = AppLeftovers.places(bundleID: "ru.keepcoder.Telegram", name: "Telegram")
        #expect(places.contains("Caches/ru.keepcoder.Telegram") && places.contains("Application Support/Telegram"))
        #expect(!AppLeftovers.places(bundleID: "x.y.app", name: "Kit").contains("Caches/Kit"))  // too short to be sure
        #expect(AppLeftovers.belongs("ru.keepcoder.Telegram.1A2B.plist", bundleID: "ru.keepcoder.Telegram"))
        #expect(AppLeftovers.belongs("6N38VWS5BX.ru.keepcoder.Telegram", bundleID: "ru.keepcoder.Telegram"))
        #expect(!AppLeftovers.belongs("com.other.app.plist", bundleID: "ru.keepcoder.Telegram"))
        #expect(!AppLeftovers.removable(bundleID: "com.apple.Notes", path: "/System/Applications/Notes.app"))
        #expect(!AppLeftovers.removable(bundleID: "org.clickbait.ClickBait", path: "/Applications/ClickBait.app"))
        #expect(AppLeftovers.removable(bundleID: "ru.keepcoder.Telegram", path: "/Applications/Telegram.app"))
    }
}
