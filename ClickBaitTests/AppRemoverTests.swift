import ClickBaitCore
import Foundation
import Testing
@testable import ClickBait

/// The uninstaller's planning on this Mac's real apps — looking only, nothing removed.
@MainActor
struct AppRemoverTests {
    @Test func plansAThirdPartyAppAndRefusesApples() throws {
        let apps = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)) ?? []
        let other = try #require(apps.first { url in
            url.pathExtension == "app" && Bundle(url: url)?.bundleIdentifier.map { !$0.hasPrefix("com.apple.") && $0 != "org.clickbait.ClickBait" } == true
        })
        guard case .ready(let plan) = AppRemover.plan(for: other) else { Issue.record("refused \(other.lastPathComponent)"); return }
        print("PLAN \(plan.name): \(plan.leftovers.count) leftovers, \(plan.bytes) bytes: \(plan.leftovers.map(\.lastPathComponent).prefix(6))")
        #expect(plan.bytes > 0)
        #expect(plan.leftovers.allSatisfy { $0.path.contains("/Library/") })
        guard case .refused = AppRemover.plan(for: URL(fileURLWithPath: "/System/Applications/Notes.app")) else { Issue.record("Notes allowed"); return }
    }
}
