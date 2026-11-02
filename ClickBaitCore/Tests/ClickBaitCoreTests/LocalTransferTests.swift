import Foundation
import Testing
@testable import ClickBaitCore

struct LocalTransferTests {
    @Test func framesRoundTrip() throws {
        let offer = LocalTransfer.Message.offer(from: "Studio Mac", files: [.init(name: "a.zip", size: 42)])
        let data = try LocalTransfer.frame(offer)
        let length = try #require(LocalTransfer.length(data.prefix(4)))
        #expect(length == data.count - 4)
        #expect(LocalTransfer.message(data.dropFirst(4)) == offer)
        #expect(LocalTransfer.length(Data([0x7F, 0, 0, 0])) == nil)  // 2 GB: refused
    }

    @Test func safeNames() {
        #expect(LocalTransfer.safeName("../../etc/passwd") == "-..-etc-passwd")
        #expect(LocalTransfer.safeName(".hidden") == "hidden")
        #expect(LocalTransfer.safeName("  ") == "file")
        #expect(LocalTransfer.safeName("photo 1.jpg") == "photo 1.jpg")
        #expect(LocalTransfer.safeName(String(repeating: "x", count: 300)).count == 200)
    }

    @Test func resume() {
        #expect(LocalTransfer.resumeOffset(partSize: nil, fileSize: 10) == 0)
        #expect(LocalTransfer.resumeOffset(partSize: 4, fileSize: 10) == 4)
        #expect(LocalTransfer.resumeOffset(partSize: 10, fileSize: 10) == 0)  // stale part: start again
        #expect(LocalTransfer.summary([.init(name: "a", size: 1000)]) == "1 file, 1 KB")
    }
}
