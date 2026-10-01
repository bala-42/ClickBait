import AppKit
import ClickBaitCore
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum FileActionError: LocalizedError {
    case nothingSelected
    case finderNotAllowed
    case differentFolders
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .nothingSelected: "Select some files in Finder first."
        case .finderNotAllowed:
            "ClickBait isn't allowed to read your Finder selection. Turn it on in System Settings → Privacy & Security → Automation."
        case .differentFolders: "The selected files need to be in the same folder."
        case .unsupported(let detail): detail
        case .failed(let detail): "That didn't work: \(detail)"
        }
    }
}

/// Runs a `FileAction` on the files selected in Finder. New files go next to the
/// originals with names that never overwrite anything, and are revealed in Finder.
/// Originals are never modified; "move to Trash" is recoverable.
enum FileActions {
    @MainActor
    static func run(_ action: FileAction) async throws -> String {
        let selection = try await FinderSelection.read()
        guard !selection.isEmpty else { throw FileActionError.nothingSelected }

        let (message, reveal): (String, [URL]) = try await Task.detached(priority: .userInitiated) {
            try perform(action, on: selection)
        }.value
        if !reveal.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(reveal) }
        return message
    }

    private static func perform(_ action: FileAction, on files: [URL]) throws -> (String, [URL]) {
        switch action {
        case .compress: return try compress(files)
        case .merge: return try merge(files)
        case .convertImages(let format): return try convert(files, to: format)
        case .moveIntoNewFolder: return try moveIntoNewFolder(files)
        case .moveToTrash: return try moveToTrash(files)
        }
    }

    // MARK: - Actions

    private static func compress(_ files: [URL]) throws -> (String, [URL]) {
        let folder = try commonFolder(of: files)
        let base = files.count == 1 ? files[0].lastPathComponent : "Archive"
        let output = folder.appending(path: try uniqueName(base: base, extension: "zip", in: folder))
        // zip keeps paths relative when run from the folder; arguments never go through a shell.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folder
        process.arguments = ["-r", "-q", "-y", output.lastPathComponent] + files.map(\.lastPathComponent)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FileActionError.failed("zip exited with \(process.terminationStatus)") }
        return ("Compressed \(count(files)) into \(output.lastPathComponent)", [output])
    }

    private static func merge(_ files: [URL]) throws -> (String, [URL]) {
        let ordered = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let folder = try commonFolder(of: ordered)
        let types = ordered.map { UTType(filenameExtension: $0.pathExtension) }

        if types.allSatisfy({ $0?.conforms(to: .pdf) == true || $0?.conforms(to: .image) == true }) {
            let merged = PDFDocument()
            for file in ordered {
                if UTType(filenameExtension: file.pathExtension)?.conforms(to: .pdf) == true {
                    guard let document = PDFDocument(url: file) else { throw FileActionError.failed("couldn't read \(file.lastPathComponent)") }
                    for index in 0..<document.pageCount {
                        if let page = document.page(at: index) { merged.insert(page, at: merged.pageCount) }
                    }
                } else {
                    guard let image = NSImage(contentsOf: file), let page = PDFPage(image: image) else {
                        throw FileActionError.failed("couldn't read \(file.lastPathComponent)")
                    }
                    merged.insert(page, at: merged.pageCount)
                }
            }
            let output = folder.appending(path: try uniqueName(base: "Merged", extension: "pdf", in: folder))
            guard merged.write(to: output) else { throw FileActionError.failed("couldn't save the PDF") }
            return ("Merged \(count(ordered)) into \(output.lastPathComponent) (\(merged.pageCount) pages, in name order)", [output])
        }

        if types.allSatisfy({ $0?.conforms(to: .text) == true }) {
            let parts = try ordered.map { try String(contentsOf: $0, encoding: .utf8) }
            let output = folder.appending(path: try uniqueName(base: "Merged", extension: "txt", in: folder))
            try parts.joined(separator: "\n\n").write(to: output, atomically: true, encoding: .utf8)
            return ("Merged \(count(ordered)) into \(output.lastPathComponent) (in name order)", [output])
        }
        throw FileActionError.unsupported("I can merge PDFs and images into one PDF, or text files into one text file.")
    }

    private static func convert(_ files: [URL], to format: ImageFormat) throws -> (String, [URL]) {
        let images = files.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        guard !images.isEmpty else { throw FileActionError.unsupported("None of the selected files are images.") }
        let (type, ext): (UTType, String) = format == .jpeg ? (.jpeg, "jpg") : (.png, "png")

        var outputs: [URL] = []
        for file in images {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw FileActionError.failed("couldn't read \(file.lastPathComponent)") }
            let folder = file.deletingLastPathComponent()
            let output = folder.appending(path: try uniqueName(base: file.deletingPathExtension().lastPathComponent, extension: ext, in: folder))
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
                throw FileActionError.failed("couldn't create \(output.lastPathComponent)")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)  // keep orientation and metadata
            CGImageDestinationAddImage(destination, image, properties)
            guard CGImageDestinationFinalize(destination) else { throw FileActionError.failed("couldn't save \(output.lastPathComponent)") }
            outputs.append(output)
        }
        let skipped = files.count - images.count
        let note = skipped > 0 ? " (skipped \(skipped) that weren't images)" : ""
        return ("Converted \(count(images)) to \(format == .jpeg ? "JPEG" : "PNG")\(note)", outputs)
    }

    private static func moveIntoNewFolder(_ files: [URL]) throws -> (String, [URL]) {
        let parent = try commonFolder(of: files)
        let folder = parent.appending(path: try uniqueName(base: "New Folder", extension: "", in: parent), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for file in files {
            try FileManager.default.moveItem(at: file, to: folder.appending(path: file.lastPathComponent))
        }
        return ("Moved \(count(files)) into \(folder.lastPathComponent)", [folder])
    }

    private static func moveToTrash(_ files: [URL]) throws -> (String, [URL]) {
        for file in files {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        return ("Moved \(count(files)) to the Trash", [])
    }

    // MARK: - Helpers

    private static func commonFolder(of files: [URL]) throws -> URL {
        let folders = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL })
        guard folders.count == 1, let folder = folders.first else { throw FileActionError.differentFolders }
        return folder
    }

    private static func uniqueName(base: String, extension ext: String, in folder: URL) throws -> String {
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        return OutputName.unique(base: base, extension: ext, existing: existing)
    }

    private static func count(_ files: [URL]) -> String {
        files.count == 1 ? "1 item" : "\(files.count) items"
    }
}

/// The files currently selected in Finder, read with AppleScript (one Automation
/// prompt for Finder the first time).
enum FinderSelection {
    static func read() async throws -> [URL] {
        let script = """
            tell application "Finder"
                set out to ""
                repeat with anItem in (selection as alias list)
                    set out to out & POSIX path of anItem & linefeed
                end repeat
                return out
            end tell
            """
        let result: Result<String, FileActionError> = await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            let output = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                let number = error[NSAppleScript.errorNumber] as? Int
                if number == -1743 { return .failure(.finderNotAllowed) }
                return .failure(.failed(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(number ?? 0)"))
            }
            return .success(output?.stringValue ?? "")
        }.value
        return try result.get()
            .split(whereSeparator: \.isNewline)
            .map { URL(fileURLWithPath: String($0)) }
    }
}
