import Foundation
import Testing
@testable import ClickBait
@testable import ClickBaitCore

/// Peek, extract and the zip styles on archives made here (macOS's own zip and tar).
struct ArchiveActionsTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-archives-\(UUID().uuidString)")

    func makeZip(_ name: String, password: String? = nil) throws -> URL {
        let source = folder.appending(path: "src")
        try FileManager.default.createDirectory(at: source.appending(path: "photos"), withIntermediateDirectories: true)
        try "hello".write(to: source.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try Data(count: 2048).write(to: source.appending(path: "photos/b c.png"))
        let zip = folder.appending(path: name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-qr"] + (password.map { ["-P", $0] } ?? []) + [zip.path, "."]
        try process.run()
        process.waitUntilExit()
        return zip
    }

    @Test func peekExtractAndZipStyles() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = try makeZip("t.zip")

        let (peek, _) = try await FileActions.perform(.peek, on: [zip])
        #expect(peek.contains("2 files") && peek.contains("a.txt") && peek.contains("photos/"))

        let (_, first) = try await FileActions.perform(.extract(to: nil), on: [zip])
        #expect(first.first?.lastPathComponent == "t")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "t/photos/b c.png").path))
        let (_, second) = try await FileActions.perform(.extract(to: nil), on: [zip])
        #expect(second.first?.lastPathComponent == "t 2")  // never over the first

        let (_, each) = try await FileActions.perform(.compress(.each), on: [folder.appending(path: "t/a.txt"), folder.appending(path: "t/photos")])
        #expect(each.map(\.lastPathComponent).sorted() == ["a.txt.zip", "photos.zip"])
        let (_, dated) = try await FileActions.perform(.compress(.dated), on: [folder.appending(path: "t/a.txt")])
        #expect(dated.first?.lastPathComponent.hasPrefix("a.txt 20") == true)

        let locked = try makeZip("locked.zip", password: "secret")
        await #expect(throws: FileActionError.self) { try await FileActions.perform(.extract(to: nil), on: [locked]) }
        do { _ = try await FileActions.perform(.extract(to: nil), on: [locked]) } catch {
            print("LOCKED: \(error.localizedDescription)")
            #expect(error.localizedDescription.contains("password-locked"))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "locked").path))  // nothing left behind
    }
}
