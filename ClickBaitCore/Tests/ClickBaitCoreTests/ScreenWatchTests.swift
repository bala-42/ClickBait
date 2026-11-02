import Foundation
import Testing
@testable import ClickBaitCore

struct ScreenWatchTests {
    let start = Date(timeIntervalSince1970: 0)

    @Test func changes() {
        var watch = ScreenWatch(rule: .changes)
        #expect(watch.see("Building…", at: start) == nil)
        #expect(watch.see("Building…", at: start + 2) == nil)
        #expect(watch.see("Build succeeded", at: start + 4) == "it changed")
    }

    @Test func finishes() {
        var watch = ScreenWatch(rule: .finishes)
        #expect(watch.see("40%", at: start) == nil)
        #expect(watch.see("70%", at: start + 2) == nil)  // still moving
        #expect(watch.see("100%", at: start + 4) == nil)
        #expect(watch.see("100%", at: start + 10) == nil)  // 6 s still
        #expect(watch.see("100%", at: start + 15) == "it finished")  // 11 s still
        var never = ScreenWatch(rule: .finishes)
        #expect(never.see("idle", at: start) == nil && never.see("idle", at: start + 60) == nil)  // never changed: not finished
    }

    @Test func saysAndReaches() {
        var says = ScreenWatch(rule: .says("done"))
        #expect(says.see("Exporting 3 of 9", at: start) == nil)
        #expect(says.see("Export Done", at: start + 2) == "it says “done”")
        var up = ScreenWatch(rule: .reaches(100))
        #expect(up.see("Uploading 42%", at: start) == nil)
        #expect(up.see("Uploading 100%", at: start + 2) != nil)
        var down = ScreenWatch(rule: .reaches(0))
        #expect(down.see("12 items left", at: start) == nil)
        #expect(down.see("0 items left", at: start + 2) != nil)
        #expect(ScreenWatch.number(in: "1,204 files") == 1204 && ScreenWatch.number(in: "3.5 GB") == 3.5)
    }
}
