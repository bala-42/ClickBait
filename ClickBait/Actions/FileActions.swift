import AppKit
@preconcurrency import AVFoundation
import ClickBaitCore
import ImageIO
import PDFKit
import Quartz
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
            try await perform(action, on: selection)
        }.value
        if !reveal.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(reveal) }
        return message
    }

    private static func perform(_ action: FileAction, on files: [URL]) async throws -> (String, [URL]) {
        switch action {
        case .compress: return try compress(files)
        case .merge: return try merge(files)
        case .convertImages(let format): return try convert(files, to: format)
        case .moveIntoNewFolder(let name): return try moveIntoNewFolder(files, name: name)
        case .moveTo(let place): return try transfer(files, to: place, copying: false)
        case .copyTo(let place): return try transfer(files, to: place, copying: true)
        case .rename(let name): return try rename(files, to: name)
        case .moveToTrash: return try moveToTrash(files)
        case .shrink: return try await shrink(files)
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

    private static func moveIntoNewFolder(_ files: [URL], name: String?) throws -> (String, [URL]) {
        let parent = try commonFolder(of: files)
        let folder = parent.appending(path: try uniqueName(base: name ?? "New Folder", extension: "", in: parent), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for file in files {
            try FileManager.default.moveItem(at: file, to: folder.appending(path: file.lastPathComponent))
        }
        return ("Moved \(count(files)) into \(folder.lastPathComponent)", [folder])
    }

    /// Moves or copies into a named place. Clashing names get a number ("Report 2.pdf");
    /// nothing is ever overwritten. Items already there are left alone.
    private static func transfer(_ files: [URL], to place: Place, copying: Bool) throws -> (String, [URL]) {
        let destination = try Places.url(for: place)
        var results: [URL] = []
        var alreadyThere = 0
        for file in files {
            if !copying, file.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL {
                alreadyThere += 1
                continue
            }
            let ext = file.pathExtension
            let base = ext.isEmpty ? file.lastPathComponent : file.deletingPathExtension().lastPathComponent
            let target = destination.appending(path: try uniqueName(base: base, extension: ext, in: destination))
            if copying {
                try FileManager.default.copyItem(at: file, to: target)
            } else {
                try FileManager.default.moveItem(at: file, to: target)
            }
            results.append(target)
        }
        guard !results.isEmpty else { return ("Already in \(place.displayName)", []) }
        let note = alreadyThere > 0 ? " (\(alreadyThere) already there)" : ""
        return ("\(copying ? "Copied" : "Moved") \(count(results)) to \(place.displayName)\(note)", results)
    }

    /// Renames the one selected item, keeping its extension unless the new name has one.
    private static func rename(_ files: [URL], to name: String) throws -> (String, [URL]) {
        guard files.count == 1, let file = files.first else {
            throw FileActionError.unsupported("Select just one item to rename.")
        }
        let ext = file.pathExtension
        let newName = (ext.isEmpty || !(name as NSString).pathExtension.isEmpty) ? name : name + "." + ext
        let target = file.deletingLastPathComponent().appending(path: newName)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw FileActionError.unsupported("There's already something called “\(newName)” there.")
        }
        try FileManager.default.moveItem(at: file, to: target)
        return ("Renamed to “\(newName)”", [target])
    }

    private static func moveToTrash(_ files: [URL]) throws -> (String, [URL]) {
        for file in files {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        return ("Moved \(count(files)) to the Trash", [])
    }

    /// Smaller copies next to the originals: images re-saved (JPEG 80%, ≤ 2560 px),
    /// PDFs through macOS's "Reduce File Size" filter, videos re-encoded to HEVC ≤ 1080p.
    /// A copy that wouldn't be meaningfully smaller is discarded.
    private static func shrink(_ files: [URL]) async throws -> (String, [URL]) {
        var outputs: [URL] = []
        var before: Int64 = 0, after: Int64 = 0
        var alreadySmall = 0, unsupported = 0

        for file in files {
            let type = UTType(filenameExtension: file.pathExtension)
            let folder = file.deletingLastPathComponent()
            let base = file.deletingPathExtension().lastPathComponent + " (smaller)"
            let output: URL
            if type?.conforms(to: .image) == true {
                output = try shrinkImage(file, base: base, in: folder)
            } else if type?.conforms(to: .pdf) == true {
                output = folder.appending(path: try uniqueName(base: base, extension: "pdf", in: folder))
                try shrinkPDF(file, to: output)
            } else if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
                output = folder.appending(path: try uniqueName(base: base, extension: "mov", in: folder))
                try await shrinkVideo(file, to: output)
            } else {
                unsupported += 1
                continue
            }

            let originalSize = fileSize(file), newSize = fileSize(output)
            if newSize >= originalSize * 97 / 100 {
                try? FileManager.default.removeItem(at: output)  // our own copy; not worth keeping
                alreadySmall += 1
                continue
            }
            before += originalSize
            after += newSize
            outputs.append(output)
        }

        var parts: [String] = []
        if !outputs.isEmpty {
            let formatter = ByteCountFormatter()
            parts.append("Made \(count(outputs)) smaller: \(formatter.string(fromByteCount: before)) → \(formatter.string(fromByteCount: after))")
        }
        if alreadySmall > 0 { parts.append("\(alreadySmall == 1 ? "1 was" : "\(alreadySmall) were") already as small as I can make it") }
        if unsupported > 0 { parts.append("skipped \(unsupported) I can't shrink (images, PDFs and videos only)") }
        guard !parts.isEmpty else { throw FileActionError.nothingSelected }
        return (parts.joined(separator: "; "), outputs)
    }

    private static func shrinkImage(_ file: URL, base: String, in folder: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw FileActionError.failed("couldn't read \(file.lastPathComponent)") }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // bake in rotation
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), 2560),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FileActionError.failed("couldn't read \(file.lastPathComponent)")
        }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let (type, ext): (UTType, String) = hasAlpha ? (.png, "png") : (.jpeg, "jpg")
        let output = folder.appending(path: try uniqueName(base: base, extension: ext, in: folder))
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw FileActionError.failed("couldn't create \(output.lastPathComponent)")
        }
        // Location and other metadata aren't copied: smaller, and nothing personal leaks.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FileActionError.failed("couldn't save \(output.lastPathComponent)") }
        return output
    }

    /// The same filter as Preview's Export → Reduce File Size: recompresses and downsamples
    /// images, keeps text selectable. (PDFKit's own write options didn't change the size.)
    private static func shrinkPDF(_ file: URL, to output: URL) throws {
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        guard let document = PDFDocument(url: file) else { throw FileActionError.failed("couldn't read \(file.lastPathComponent)") }
        guard let filter = QuartzFilter(url: filterURL) else {
            throw FileActionError.unsupported("This Mac is missing the system PDF filter needed to shrink PDFs.")
        }
        guard document.write(to: output, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
            throw FileActionError.failed("couldn't shrink \(file.lastPathComponent)")
        }
    }

    private static func shrinkVideo(_ file: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: file)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw FileActionError.failed("can't re-encode \(file.lastPathComponent)")
        }
        session.shouldOptimizeForNetworkUse = true
        if #available(macOS 15.0, *) {
            try await session.export(to: output, as: .mov)
        } else {
            session.outputURL = output
            session.outputFileType = .mov
            await session.export()
            if let error = session.error { throw FileActionError.failed(error.localizedDescription) }
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
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
    /// Selects these files in Finder where they're shown (front window or desktop).
    /// Returns how many were selected. Paths reach AppleScript only as escaped literals.
    static func select(_ urls: [URL]) async throws -> Int {
        guard !urls.isEmpty else { return 0 }
        let script = """
            set wanted to \(AppleScriptText.list(urls.map(\.path)))
            tell application "Finder"
                set found to {}
                repeat with aPath in wanted
                    try
                        set end of found to ((POSIX file (aPath as text)) as alias)
                    end try
                end repeat
                if (count of found) > 0 then select found
                return count of found
            end tell
            """
        let result: Result<Int, FileActionError> = await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            let output = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                let number = error[NSAppleScript.errorNumber] as? Int
                if number == -1743 { return .failure(.finderNotAllowed) }
                return .failure(.failed(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(number ?? 0)"))
            }
            return .success(Int(output?.int32Value ?? 0))
        }.value
        return try result.get()
    }

    /// The folder shown in the front Finder window, if there is one.
    static func frontFolder() async -> URL? {
        let script = """
            tell application "Finder"
                if (count of Finder windows) is 0 then return ""
                return POSIX path of (target of front Finder window as alias)
            end tell
            """
        let path: String = await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            return NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue ?? ""
        }.value
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

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
