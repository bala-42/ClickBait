import ClickBaitCore
import Foundation
import Testing
@testable import ClickBait

/// The archive browser's reading on real zips: a zip inside a zip listed and taken from by
/// streaming, and smart extraction's two cases.
struct ArchiveBrowserTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "browser-\(UUID().uuidString)")

    private func zip(_ folder: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folder
        process.arguments = ["-qr", archive.path, "."]
        try process.run()
        process.waitUntilExit()
    }

    /// outer.zip: top.txt, inner.zip (deep.txt, docs/notes[1]*.txt).
    private func fixture() throws -> URL {
        let inner = root.appending(path: "in"), outer = root.appending(path: "out")
        try FileManager.default.createDirectory(at: inner.appending(path: "docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        try "hello".write(to: inner.appending(path: "docs/notes[1]*.txt"), atomically: true, encoding: .utf8)
        try "deep".write(to: inner.appending(path: "deep.txt"), atomically: true, encoding: .utf8)
        try zip(inner, to: outer.appending(path: "inner.zip"))
        try "top".write(to: outer.appending(path: "top.txt"), atomically: true, encoding: .utf8)
        try zip(outer, to: root.appending(path: "outer.zip"))
        return root.appending(path: "outer.zip")
    }

    @Test func nestedListAndTakeOut() async throws {
        let outer = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let top = ArchiveListing.entries(try await ArchiveReader.list(ArchiveLevel(file: outer, inner: [])))
        #expect(ArchiveTree.children(of: "", in: top).map(\.name).sorted() == ["inner.zip", "top.txt"])
        let level = ArchiveLevel(file: outer, inner: ["inner.zip"])
        let entries = ArchiveListing.entries(try await ArchiveReader.list(level))
        let docs = ArchiveTree.children(of: "docs/", in: entries)
        let notes = try #require(docs.first)
        let out = root.appending(path: "taken")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = try await ArchiveReader.extract(notes, from: level, into: out)
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello")
    }

    @Test func smartExtraction() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appending(path: "dest")
        // One folder: lands as itself, not inside another.
        let one = parent.appending(path: ".s1")
        try FileManager.default.createDirectory(at: one.appending(path: "photos"), withIntermediateDirectories: true)
        let landed = try FileActions.placeExtracted(one, beside: parent, named: "photos")
        #expect(landed.lastPathComponent == "photos")
        #expect(!FileManager.default.fileExists(atPath: landed.appending(path: "photos").path))
        // Several: a folder named after the archive.
        let many = parent.appending(path: ".s2")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        try "a".write(to: many.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: many.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        let folder = try FileActions.placeExtracted(many, beside: parent, named: "bundle")
        #expect(folder.lastPathComponent == "bundle")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "a.txt").path))
    }
}
