import AppKit
import Foundation
import Testing
@testable import ClickBait
@testable import ClickBaitCore

/// Converting every kind of file, end to end (opt-in): `TEST_RUNNER_CLICKBAIT_CONVERT_ALL=<video>|<broken video>`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_CONVERT_ALL"] != nil))
struct ConvertAllTests {
    @Test func everyKind() async throws {
        let paths = (ProcessInfo.processInfo.environment["CLICKBAIT_CONVERT_ALL"] ?? "").split(separator: "|").map(String.init)
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-convert-all")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func check(_ files: [URL], _ format: FileFormat) async {
            do {
                let (message, outputs) = try await FileActions.perform(.convert(to: format), on: files)
                let sizes = outputs.map { "\($0.lastPathComponent) \(((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.intValue ?? 0) / 1024) KB" }
                print("CONVERT \(files.map(\.pathExtension).joined(separator: ",")) → \(format.rawValue): \(message) [\(sizes.joined(separator: "; "))]")
            } catch {
                print("CONVERT \(files.map(\.pathExtension).joined(separator: ",")) → \(format.rawValue): ERROR \(error.localizedDescription)")
            }
        }
        // A document: text → Word → PDF → text, Word → RTF, web page, OpenDocument.
        let text = folder.appending(path: "notes.txt")
        try String(repeating: "Studio is the notch's new teleprompter. It follows your voice and runs on this Mac.\n\n", count: 40).write(to: text, atomically: true, encoding: .utf8)
        await check([text], .docx)
        let word = folder.appending(path: "notes.docx")
        await check([word], .pdf)
        await check([word], .rtf)
        await check([word], .html)
        await check([word], .odt)
        let pdf = folder.appending(path: "notes.pdf")
        await check([pdf], .txt)
        await check([pdf], .docx)
        await check([pdf], .png)
        // An image: PNG → JPEG, HEIC, PDF.
        let image = NSImage(size: NSSize(width: 400, height: 300), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let png = folder.appending(path: "picture.png")
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: png)
        await check([png], .jpeg)
        await check([png], .heic)
        await check([png], .pdf)
        // Videos: a real one to MP4 and MOV; a cut-off one.
        if paths.count > 0 {
            let video = folder.appending(path: "clip.mov")
            try FileManager.default.copyItem(atPath: paths[0], toPath: video.path)
            await check([video], .mp4)
        }
        if paths.count > 1 {
            let broken = folder.appending(path: "broken.mov")
            try FileManager.default.copyItem(atPath: paths[1], toPath: broken.path)
            await check([broken], .mp4)
        }
        // A mismatch: a PDF to MP4.
        await check([pdf], .mp4)
        try? FileManager.default.removeItem(at: folder)
    }
}
