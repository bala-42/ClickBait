import Foundation
import Testing
@testable import ClickBaitCore

struct ArchiveTreeTests {
    let entries: [ArchiveListing.Entry] = [
        .init(path: "photos/", bytes: 0, date: "Nov  2 18:07"),
        .init(path: "photos/cat.jpg", bytes: 300, date: "Nov  2 18:07"),
        .init(path: "photos/2024/dog.jpg", bytes: 200, date: "Mar  4  2024"),
        .init(path: "readme.txt", bytes: 10, date: "Nov  1 09:00"),
        .init(path: "inner.zip", bytes: 50, date: "Nov  1 09:00"),
    ]

    @Test func children() {
        let top = ArchiveTree.children(of: "", in: entries)
        #expect(top.map(\.name) == ["photos", "inner.zip", "readme.txt"])
        #expect(top[0].isFolder && top[0].bytes == 500)
        #expect(top[1].isArchive && !top[2].isArchive)
        let photos = ArchiveTree.children(of: "photos/", in: entries)
        #expect(photos.map(\.name) == ["2024", "cat.jpg"])  // "2024/" made up from its file's path
        #expect(photos.first?.path == "photos/2024/")
    }

    @Test func searchAndPatterns() {
        #expect(ArchiveTree.search("JPG", in: entries).map(\.name) == ["cat.jpg", "dog.jpg"])
        #expect(ArchiveTree.tarPattern("a/notes[1]*.txt") == #"a/notes\[1]\*.txt"#)
    }

    @Test func smartExtraction() {
        #expect(!ArchiveTree.extractsIntoOwnFolder(Array(entries.prefix(3))))  // one folder: lands as itself
        #expect(ArchiveTree.extractsIntoOwnFolder(entries))  // several: a folder named after the archive
    }

    @Test func dates() {
        let now = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!
        let recent = ArchiveTree.parseDate("Nov  1 09:00", now: now)!
        #expect(Calendar.current.component(.year, from: recent) == 2026)
        let ahead = ArchiveTree.parseDate("Dec 25 09:00", now: now)!
        #expect(Calendar.current.component(.year, from: ahead) == 2025)
        #expect(ArchiveTree.parseDate("Mar  4  2024", now: now).map { Calendar.current.component(.year, from: $0) } == 2024)
        #expect(ArchiveTree.parseDate("2 Nov 18:41", now: now).map { Calendar.current.component(.day, from: $0) } == 2)
    }
}
