import Foundation
import Testing
@testable import ClickBaitCore

struct AppBlocklistTests {
    @Test func defaultsBlockPasswordManagersAndKeychain() {
        let list = AppBlocklist.defaults
        #expect(list.isBlocked(bundleID: "com.apple.keychainaccess"))
        #expect(list.isBlocked(bundleID: "com.1password.1password"))
        #expect(!list.isBlocked(bundleID: "com.apple.Safari"))
    }

    @Test func matchingIgnoresCase() {
        #expect(AppBlocklist.defaults.isBlocked(bundleID: "COM.APPLE.KEYCHAINACCESS"))
    }

    @Test func missingBundleIDIsNotBlocked() {
        #expect(!AppBlocklist.defaults.isBlocked(bundleID: nil))
        #expect(!AppBlocklist.defaults.isBlocked(bundleID: ""))
    }

    @Test func addIgnoresDuplicatesAndEmptyIDs() {
        var list = AppBlocklist(apps: [])
        list.add(BlockedApp(bundleID: "com.example.App", name: "App"))
        list.add(BlockedApp(bundleID: "com.EXAMPLE.app", name: "App again"))
        list.add(BlockedApp(bundleID: "", name: "Nameless"))
        #expect(list.apps.map(\.name) == ["App"])
    }

    @Test func initDeduplicates() {
        let list = AppBlocklist(apps: [
            BlockedApp(bundleID: "a.b", name: "One"),
            BlockedApp(bundleID: "A.B", name: "Two"),
        ])
        #expect(list.apps.count == 1)
    }

    @Test func removeIgnoresCase() {
        var list = AppBlocklist.defaults
        list.remove(bundleID: "COM.APPLE.keychainaccess")
        #expect(!list.isBlocked(bundleID: "com.apple.keychainaccess"))
        #expect(list.isBlocked(bundleID: "com.1password.1password"))
    }

    @Test func roundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(AppBlocklist.defaults)
        let decoded = try JSONDecoder().decode(AppBlocklist.self, from: data)
        #expect(decoded == AppBlocklist.defaults)
    }
}
