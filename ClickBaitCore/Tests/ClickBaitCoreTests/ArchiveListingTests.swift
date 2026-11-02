import Testing
@testable import ClickBaitCore

struct ArchiveListingTests {
    // Real output of `tar -tvf` on a zip (2026-11-02).
    let listing = """
        -rw-r--r--  0 501    0           6  2 Nov 13:25 a.txt
        drwxr-xr-x  0 501    0           0  2 Nov 13:25 photos/
        -rw-r--r--  0 501    0        2048  2 Nov 13:25 photos/b c.png
        -rw-r--r--  0 501    0          10  2 Nov 13:25 __MACOSX/._a.txt
        """

    @Test func readsNamesSizesAndFolders() {
        let entries = ArchiveListing.entries(listing)
        #expect(entries.map(\.path) == ["a.txt", "photos/", "photos/b c.png"])
        #expect(entries.filter { !$0.isFolder }.reduce(0) { $0 + $1.bytes } == 2054)
        #expect(ArchiveListing.topLevel(entries) == ["a.txt", "photos/"])
    }
}
