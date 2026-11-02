import Testing
@testable import ClickBaitCore

struct LinkCleanerTests {
    @Test func takesOffTrackingOnly() {
        #expect(LinkCleaner.clean("https://shop.example/item?id=42&utm_source=mail&utm_medium=x&fbclid=abc") == "https://shop.example/item?id=42")
        #expect(LinkCleaner.clean("https://youtu.be/abc?si=xyz") == "https://youtu.be/abc")
        #expect(LinkCleaner.clean("https://example.com/?q=swift") == nil)  // nothing to take off
        #expect(LinkCleaner.clean("see https://x.com/?utm_source=a") == nil)  // not just a link
        #expect(LinkCleaner.clean("ftp://x/?utm_source=a") == nil)
    }
}
