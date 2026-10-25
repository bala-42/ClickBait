import AppKit
import Foundation
import Testing
@testable import ClickBait

/// A photo's ✕ in Mirror takes it out of the strip and deletes its temporary file (2026-10-25).
@MainActor
struct MirrorDeleteTests {
    @Test func theCrossDeletesOnePhoto() throws {
        let camera = CameraMirrorModel()
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-mirror")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (0..<2).map { folder.appending(path: "shot-\($0).jpg") }
        for file in files { try Data([1, 2, 3]).write(to: file) }
        let shots = files.map { CameraMirrorModel.Shot(image: NSImage(size: NSSize(width: 4, height: 4)), file: $0) }
        shots.forEach(camera.debugAdd)
        camera.delete(shots[0])
        #expect(camera.shots.map(\.id) == [shots[1].id])
        #expect(!FileManager.default.fileExists(atPath: files[0].path))
        #expect(FileManager.default.fileExists(atPath: files[1].path))  // the other one stays
    }
}
