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

/// Runs a `FileAction` on the files chosen: for actions that only make new files
/// (`FileAction.makesCopies`), the files selected on the shelf, else the document open in the
/// app in front, else Finder's selection (user's ask, 2026-11-01: "why only from Finder?");
/// for the rest, Finder's selection. New files go next to the originals with names that never
/// overwrite anything, and are revealed in Finder (or put on the shelf, when they came from
/// it). Originals are never modified; "move to Trash" is recoverable.
enum FileActions {
    /// Set by the notch: the shelf's selected files, and putting new files on the shelf.
    @MainActor static var shelfSelection: () -> [URL] = { [] }
    @MainActor static var addToShelf: ([URL]) -> Void = { _ in }

    /// Where the files for `action` come from right now, without asking Finder; nil means Finder.
    @MainActor
    static func otherSource(for action: FileAction, frontmostPID: pid_t?, frontmostBundleID: String?) -> (files: [URL], shelf: Bool)? {
        guard action.makesCopies else { return nil }
        let shelf = shelfSelection()
        if !shelf.isEmpty { return (shelf, true) }
        if frontmostBundleID != FileAction.requiredFrontmostApp, let document = AXInspector.openDocument(frontmostPID: frontmostPID) {
            return ([document], false)
        }
        return nil
    }

    /// `reveal` false (a dock job): nothing is brought forward; the card shows the files later.
    @MainActor
    static func run(_ action: FileAction, reveal: Bool = true) async throws -> (message: String, made: [URL]) {
        let front = NSWorkspace.shared.frontmostApplication
        let source = otherSource(for: action, frontmostPID: front?.processIdentifier, frontmostBundleID: front?.bundleIdentifier)
        let selection: [URL]
        if let source { selection = source.files } else { selection = try await FinderSelection.read() }
        guard !selection.isEmpty else { throw FileActionError.nothingSelected }

        let (message, made): (String, [URL]) = try await Task.detached(priority: .userInitiated) {
            try await perform(action, on: selection)
        }.value
        if source?.shelf == true {
            addToShelf(made)
        } else if reveal, !made.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(made)
        }
        return (message, made)
    }

    static func perform(_ action: FileAction, on files: [URL]) async throws -> (String, [URL]) {
        switch action {
        case .compress: return try compress(files)
        case .merge: return try merge(files)
        case .convert(let format): return try await convert(files, to: format)
        case .moveIntoNewFolder(let name): return try moveIntoNewFolder(files, name: name)
        case .moveTo(let place): return try transfer(files, to: place, copying: false)
        case .copyTo(let place): return try transfer(files, to: place, copying: true)
        case .moveToFolder(let name): return try transfer(files, intoFolderNamed: name, copying: false)
        case .copyToFolder(let name): return try transfer(files, intoFolderNamed: name, copying: true)
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

    /// Every file to `format`, by what it is (user's ask, 2026-11-01): videos, images, PDFs and
    /// documents. Files the format doesn't fit are skipped and named.
    private static func convert(_ files: [URL], to format: FileFormat) async throws -> (String, [URL]) {
        var outputs: [URL] = []
        var skipped: [String] = []
        for file in files {
            let type = UTType(filenameExtension: file.pathExtension)
            let folder = file.deletingLastPathComponent()
            let base = file.deletingPathExtension().lastPathComponent
            let output = folder.appending(path: try uniqueName(base: base, extension: format.fileExtension, in: folder))
            if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
                guard [.mp4, .mov, .m4v, .m4a, .gif].contains(format) else { skipped.append(file.lastPathComponent); continue }
                try await convertVideo(file, to: output, format: format)
                outputs.append(output)
            } else if type?.conforms(to: .pdf) == true {
                outputs += try convertPDF(file, to: format, base: base, in: folder)
            } else if type?.conforms(to: .image) == true {
                guard [.jpeg, .png, .heic, .tiff, .gif, .bmp, .pdf].contains(format) else { skipped.append(file.lastPathComponent); continue }
                try convertImage(file, to: output, format: format)
                outputs.append(output)
            } else if let attributed = readDocument(file) {
                try writeDocument(attributed, to: output, format: format)
                outputs.append(output)
            } else {
                skipped.append(file.lastPathComponent)
            }
        }
        guard !outputs.isEmpty else {
            throw FileActionError.unsupported("I can't make \(format.label) from \(skipped.joined(separator: ", ")).")
        }
        let note = skipped.isEmpty ? "" : " (skipped \(skipped.count) that can't become \(format.label))"
        return ("Converted \(count(outputs)) to \(format.label)\(note)", outputs)
    }

    private static func convertVideo(_ file: URL, to output: URL, format: FileFormat) async throws {
        // A cut-off copy (no index) can't be read by anything: say so, not "can't make MP4".
        let asset = AVURLAsset(url: file)
        guard (try? await asset.load(.isReadable)) == true, let seconds = try? await asset.load(.duration).seconds,
              seconds.isFinite, seconds > 0 else {
            throw FileActionError.failed("\(file.lastPathComponent) is damaged or unfinished (it was cut off while being made), so I can't read it")
        }
        switch format {
        case .gif: try await makeGIF(file, to: output)
        case .m4a: try await export(file, to: output, as: .m4a, presets: [AVAssetExportPresetAppleM4A])
        case .mov: try await export(file, to: output, as: .mov, presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality])
        case .m4v: try await export(file, to: output, as: .m4v, presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality])
        default: try await export(file, to: output, as: .mp4, presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality])
        }
    }

    /// An image to another image format (orientation and metadata kept), or to a one-page PDF.
    private static func convertImage(_ file: URL, to output: URL, format: FileFormat) throws {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw FileActionError.failed("couldn't read \(file.lastPathComponent)") }
        if format == .pdf {
            guard let page = PDFPage(image: NSImage(cgImage: image, size: .zero)) else { throw FileActionError.failed("couldn't make a PDF of \(file.lastPathComponent)") }
            let document = PDFDocument()
            document.insert(page, at: 0)
            guard document.write(to: output) else { throw FileActionError.failed("couldn't save \(output.lastPathComponent)") }
            return
        }
        let type: UTType = switch format {
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        default: .jpeg
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw FileActionError.failed("couldn't create \(output.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        guard CGImageDestinationFinalize(destination) else { throw FileActionError.failed("couldn't save \(output.lastPathComponent)") }
    }

    /// A PDF to text or a document (its text, page after page), or to images (one per page).
    private static func convertPDF(_ file: URL, to format: FileFormat, base: String, in folder: URL) throws -> [URL] {
        guard let document = PDFDocument(url: file) else { throw FileActionError.failed("couldn't read \(file.lastPathComponent)") }
        switch format {
        case .jpeg, .png, .heic, .tiff, .bmp, .gif:
            var pages: [URL] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let picture = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
                guard let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let name = document.pageCount == 1 ? base : "\(base) page \(index + 1)"
                let output = folder.appending(path: try uniqueName(base: name, extension: format.fileExtension, in: folder))
                let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
                guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
                try convertImage(temporary, to: output, format: format)
                try? FileManager.default.removeItem(at: temporary)
                pages.append(output)
            }
            return pages
        case .pdf:
            throw FileActionError.unsupported("\(file.lastPathComponent) is already a PDF.")
        case .mp4, .mov, .m4v, .m4a:
            throw FileActionError.unsupported("A PDF can't become \(format.label).")
        default:
            let text = NSMutableAttributedString()
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.attributedString { text.append(page) }
                if index < document.pageCount - 1 { text.append(NSAttributedString(string: "\n\n")) }
            }
            let output = folder.appending(path: try uniqueName(base: base, extension: format.fileExtension, in: folder))
            try writeDocument(text, to: output, format: format)
            return [output]
        }
    }

    /// A document's text and formatting: Word (.docx, .doc), RTF, plain text, Markdown, a web page, OpenDocument.
    private static func readDocument(_ file: URL) -> NSAttributedString? {
        let ext = file.pathExtension.lowercased()
        guard ["docx", "doc", "rtf", "rtfd", "txt", "text", "md", "markdown", "html", "htm", "odt", "webarchive"].contains(ext) else { return nil }
        return try? NSAttributedString(url: file, options: [:], documentAttributes: nil)
    }

    private static func writeDocument(_ text: NSAttributedString, to output: URL, format: FileFormat) throws {
        let range = NSRange(location: 0, length: text.length)
        let type: NSAttributedString.DocumentType
        switch format {
        case .pdf:
            try writePDF(text, to: output)
            return
        case .docx: type = .officeOpenXML
        case .doc: type = .docFormat
        case .rtf: type = .rtf
        case .txt: type = .plain
        case .html: type = .html
        case .odt: type = .openDocument
        default: throw FileActionError.unsupported("A document can't become \(format.label).")
        }
        let data = try text.data(from: range, documentAttributes: [.documentType: type])
        try data.write(to: output)
    }

    /// Text laid out on A4 pages with 2 cm margins (Core Text), as a PDF.
    private static func writePDF(_ text: NSAttributedString, to output: URL) throws {
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(output as CFURL, mediaBox: &page, nil) else { throw FileActionError.failed("couldn't create \(output.lastPathComponent)") }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var start = 0
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: page.insetBy(dx: 57, dy: 57), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let shown = CTFrameGetVisibleStringRange(frame).length
            context.endPDFPage()
            guard shown > 0 else { break }
            start += shown
        } while start < text.length
        context.closePDF()
    }

    /// The first preset that can write `type` (passthrough first: no re-encoding, no loss).
    private static func export(_ file: URL, to output: URL, as type: AVFileType, presets: [String]) async throws {
        let asset = AVURLAsset(url: file)
        var lastError: Error?
        for preset in presets {
            // Tried, not asked: the "compatible types" answer said no for videos it can export.
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            do {
                try? FileManager.default.removeItem(at: output)
                try await session.export(to: output, as: type)
                return
            } catch {
                lastError = error
            }
        }
        try? FileManager.default.removeItem(at: output)
        throw FileActionError.failed(lastError?.localizedDescription ?? "can't make \(type.rawValue) from \(file.lastPathComponent)")
    }

    /// An animated GIF: up to 150 frames spread across the video (at most 10 a second), 480 px
    /// wide, looping.
    private static func makeGIF(_ file: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: file)
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw FileActionError.failed("couldn't read \(file.lastPathComponent)") }
        let frames = max(2, min(150, Int(seconds * 10)))
        let step = seconds / Double(frames)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: step, preferredTimescale: 600)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw FileActionError.failed("couldn't create \(output.lastPathComponent)")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step]] as CFDictionary
        for index in 0..<frames {
            let time = CMTime(seconds: Double(index) * step, preferredTimescale: 600)
            guard let frame = try? await generator.image(at: time).image else { continue }
            CGImageDestinationAddImage(destination, frame, delay)
        }
        guard CGImageDestinationFinalize(destination) else { throw FileActionError.failed("couldn't save \(output.lastPathComponent)") }
    }

    private static func moveIntoNewFolder(_ files: [URL], name: String?) throws -> (String, [URL]) {
        let parent = try commonFolder(of: files)
        let folder = parent.appending(path: try uniqueName(base: name ?? "New Folder", extension: "", in: parent), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        Places.lastCreatedFolder = folder
        for file in files {
            try FileManager.default.moveItem(at: file, to: folder.appending(path: file.lastPathComponent))
        }
        return ("Moved \(count(files)) into \(folder.lastPathComponent)", [folder])
    }

    /// Moves or copies into a named place. Clashing names get a number ("Report 2.pdf");
    /// nothing is ever overwritten. Items already there are left alone.
    private static func transfer(_ files: [URL], to place: Place, copying: Bool) throws -> (String, [URL]) {
        try transfer(files, to: try Places.url(for: place), named: place.displayName, copying: copying)
    }

    /// Into a folder next to the files: "new folder" is the one ClickBait just made (or
    /// the newest untitled one); otherwise matched by name, ignoring case.
    private static func transfer(_ files: [URL], intoFolderNamed name: String, copying: Bool) throws -> (String, [URL]) {
        let parent = try commonFolder(of: files)
        let selected = Set(files.map(\.standardizedFileURL))
        let folders = ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !selected.contains($0.standardizedFileURL) }
        let target: URL?
        if FolderReference.meansJustMade(name) {
            if let made = Places.lastCreatedFolder, folders.contains(where: { $0.standardizedFileURL == made.standardizedFileURL }) {
                target = made
            } else {
                target = folders
                    .filter { ["untitled folder", "new folder"].contains(where: $0.lastPathComponent.lowercased().hasPrefix) }
                    .max { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            }
        } else {
            target = folders.first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
                ?? ActionCatalog.bestMatch(for: name, in: folders.map(\.lastPathComponent)).flatMap { match in
                    folders.first { $0.lastPathComponent == match }
                }
        }
        guard let target else {
            throw FileActionError.unsupported("There's no folder called “\(name)” next to these files.")
        }
        return try transfer(files, to: target, named: "“\(target.lastPathComponent)”", copying: copying)
    }

    private static func transfer(_ files: [URL], to destination: URL, named placeName: String, copying: Bool) throws -> (String, [URL]) {
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
        guard !results.isEmpty else { return ("Already in \(placeName)", []) }
        let note = alreadyThere > 0 ? " (\(alreadyThere) already there)" : ""
        return ("\(copying ? "Copied" : "Moved") \(count(results)) to \(placeName)\(note)", results)
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
                // Made in a temporary file and moved in only when complete: a shrink cut off
                // part-way (the app quit) left a broken copy with a normal name (user's report).
                let partial = FileManager.default.temporaryDirectory.appending(path: "ClickBait-shrinking-\(UUID().uuidString).mov")
                do {
                    try await shrinkVideo(file, to: partial)
                    try FileManager.default.moveItem(at: partial, to: output)
                } catch {
                    try? FileManager.default.removeItem(at: partial)
                    throw error
                }
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

    /// HEVC at about half the original's bitrate (at least 0.8 Mbit/s), at most 1080p, AAC
    /// audio at 128 kbit/s. Apple's HEVC 1080p preset picks its own, higher bitrate, so already
    /// efficient videos (a 1080p H.264 at 3.3 Mbit/s here) came out no smaller and were
    /// discarded: "it can not shrink my videos" (user's report, 2026-11-01).
    private static func shrinkVideo(_ file: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: file)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw FileActionError.failed("\(file.lastPathComponent) has no picture to shrink")
        }
        let (natural, transform, rate) = try await video.load(.naturalSize, .preferredTransform, .estimatedDataRate)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        // Up to 1080 on the short side, the shape kept; even sizes, as encoders want.
        let scale = min(1, 1080 / max(1, min(natural.width, natural.height)))
        let width = Int((natural.width * scale / 2).rounded()) * 2, height = Int((natural.height * scale / 2).rounded()) * 2
        let bitrate = max(800_000, Double(rate) * 0.5 * Double(scale * scale))

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let audio {
            let out = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(out)
            audioOut = out
        }

        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]
        ])
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44_100, AVEncoderBitRateKey: 128_000
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        guard reader.startReading(), writer.startWriting() else {
            throw FileActionError.failed("can't re-encode \(file.lastPathComponent)")
        }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pump(videoOut, into: videoIn, label: "video") }
            if let audioOut, let audioIn { group.addTask { await Self.pump(audioOut, into: audioIn, label: "audio") } }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw FileActionError.failed(reader.error?.localizedDescription ?? "couldn't read \(file.lastPathComponent)")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw FileActionError.failed(writer.error?.localizedDescription ?? "couldn't write \(output.lastPathComponent)")
        }
    }

    /// Copies one track's samples from the reader into the writer, as fast as the writer takes them.
    private static func pump(_ output: AVAssetReaderTrackOutput, into input: AVAssetWriterInput, label: String) async {
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "clickbait.shrink.\(label)")) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                    input.append(sample)
                }
            }
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

private extension URL {
    var creationDate: Date? { try? resourceValues(forKeys: [.creationDateKey]).creationDate }
}
