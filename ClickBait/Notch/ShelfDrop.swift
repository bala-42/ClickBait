import AppKit
import ClickBaitCore
import UniformTypeIdentifiers

/// Anything dragged onto the notch from any app goes on the shelf (user's ask, 2026-11-01):
/// files from Finder or VS Code, Mail attachments, Photos, an image from a web page or Google
/// Images, the screenshot thumbnail, text. Many apps don't drag a file at all: they promise
/// one, or hand over image data or a web link. Each becomes a real file in ClickBait's shelf
/// folder. A link with nothing else is downloaded only with Internet Mode on (🌐).
/// What happened is said in the companion's pill.
@MainActor
enum ShelfDrop {
    /// What the notch accepts. `.data` last, so promised files of any kind still come in.
    static let types: [UTType] = [.fileURL, .image, .pdf, .movie, .audio, .url, .plainText, .data]

    /// Set by the app delegate: a line in the companion's pill.
    static var say: ((String, CompanionTone) -> Void)?
    /// An archive just landed on the shelf: the app offers "peek at it?".
    static var offerPeek: ((URL) -> Void)?
    /// Set by the notch: whether Internet Mode is on.
    static var internetOn: () -> Bool = { false }

    /// Files made from drags live here; emptied at each launch (the shelf itself is per session).
    static let folder: URL = {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "ClickBait/Shelf", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    struct Refusal: Error { let message: String }

    // MARK: Paste (user's ask, 2026-11-01)

    /// What's on the clipboard, as the same items a drag would carry: copied files (Finder's
    /// ⌘C), else a copied image, else a web link, else text.
    static func clipboardItems() -> [NSItemProvider] {
        let board = NSPasteboard.general
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            return files.compactMap { NSItemProvider(contentsOf: $0) }
        }
        if let image = (board.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first {
            return [NSItemProvider(object: image)]
        }
        if let link = (board.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, link.scheme?.hasPrefix("http") == true {
            return [NSItemProvider(object: link as NSURL)]
        }
        if let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [NSItemProvider(object: text as NSString)]
        }
        return []
    }

    static var canPaste: Bool {
        let board = NSPasteboard.general
        return board.canReadObject(forClasses: [NSURL.self, NSImage.self], options: nil) || board.string(forType: .string) != nil
    }

    /// Pastes the clipboard onto the shelf, like dropping it there.
    @discardableResult
    static func paste(into shelf: ShelfStore) -> Bool {
        let items = clipboardItems()
        guard !items.isEmpty else { say?("nothing to paste", .error); return false }
        return take(items, into: shelf)
    }

    private static var pasteMonitor: Any?
    /// The shelf is on screen (set by its view): ⌘V goes to it only then.
    static var shelfShown = false

    /// ⌘V while the notch is the key window and the shelf shows: pastes onto it. Typing in
    /// a text field there (the quick note, a rename) keeps its own paste.
    static func listenForPaste(shelf: ShelfStore) {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let window = event.window, window.level == WindowLayers.notch,
                  !(window.firstResponder is NSText) else { return event }
            guard MainActor.assumeIsolated({ shelfShown }) else { return event }
            MainActor.assumeIsolated { _ = paste(into: shelf) }
            return nil
        }
    }

    /// Makes the notch the key window, so ⌘V reaches it (it doesn't take focus by itself).
    static func focusNotch() {
        NSApp.windows.first { $0.isVisible && $0.canBecomeKey && $0.level == WindowLayers.notch }?.makeKey()
    }

    /// Takes a drop: true when there was something to take (the work carries on after).
    static func take(_ providers: [NSItemProvider], into shelf: ShelfStore) -> Bool {
        guard !providers.isEmpty else { return false }
        _ = folder  // made (and last session's emptied) before any file lands in it
        say?("adding…", .processing)
        Task { @MainActor in
            var added: [URL] = []
            var refusal: String?
            for provider in providers {
                do { added.append(try await file(from: provider)) } catch let error as Refusal {
                    refusal = error.message
                } catch {
                    refusal = "couldn't add that: \(error.localizedDescription)"
                }
            }
            shelf.add(added)
            if let first = added.first {
                say?(added.count == 1 ? "added \(first.lastPathComponent) to your shelf ✓" : "added \(added.count) files to your shelf ✓", .action)
            } else {
                say?(refusal ?? "couldn't add that", .error)
            }
            Log.app.notice("Shelf drop: \(added.count, privacy: .public) added, \(providers.count, privacy: .public) dragged")
            if let archive = added.first(where: FileActions.isArchive) {
                try? await Task.sleep(for: .seconds(1.4))  // after "added … ✓" has been read
                offerPeek?(archive)
            }
        }
        return true
    }

    /// One dragged item as a file on disk: the file itself, a promised or carried file, a web
    /// link downloaded, or text saved.
    private static func file(from provider: NSItemProvider) async throws -> URL {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await fileURL(from: provider), FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // A file in the drag (promised, or carried as data): the picture first, then PDFs,
        // video, audio, anything that isn't text or a link, each tried until one works. A
        // browser offers several for one image, and the first was often its own drag type or
        // a web archive, so web images often added nothing (user's report, 2026-11-01).
        let offered = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        let files = offered.filter { $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url) }
        let rank: (UTType) -> Int = { type in
            if type.conforms(to: .image) { return 0 }
            if type.conforms(to: .pdf) || type.conforms(to: .movie) || type.conforms(to: .audio) { return 1 }
            if type.identifier.hasPrefix("dyn.") || type.identifier.contains("chromium") || type == .webArchive { return 3 }
            return 2
        }
        for type in files.sorted(by: { rank($0) < rank($1) }) {
            if let url = try? await copy(provider, type: type) { return url }
            if let url = try? await save(provider, type: type) { return url }  // carried as data, not a file
        }
        // Last, the picture itself (an image the browser hands over only as an image object).
        if provider.canLoadObject(ofClass: NSImage.self), let url = try? await savePicture(provider) { return url }
        if !files.isEmpty {
            Log.app.notice("Shelf drop: no file from \(provider.registeredTypeIdentifiers.joined(separator: ", "), privacy: .public)")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let link = try? await webURL(from: provider), let scheme = link.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            guard internetOn() else { throw Refusal(message: "that's a web link: switch on 🌐 to download it") }
            return try await download(link)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String, !text.isEmpty {
            let name = text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(40)) } ?? "text"
            let url = unique("\(name.replacingOccurrences(of: "/", with: "-")).txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        throw Refusal(message: "couldn't add that: the app didn't hand over a file")
    }

    private static func fileURL(from provider: NSItemProvider) async throws -> URL? {
        let item = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return item as? URL
    }

    private static func webURL(from provider: NSItemProvider) async throws -> URL? {
        let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return item as? URL
    }

    /// The provider writes its file somewhere temporary that's gone once it calls back: copy it out.
    /// The item's bytes for `type`, written to a file named from the drag.
    private static func save(_ provider: NSItemProvider, type: UTType) async throws -> URL {
        let suggested = provider.suggestedName
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) } else {
                    continuation.resume(throwing: error ?? Refusal(message: "couldn't add that"))
                }
            }
        }
        var name = suggested ?? (type.conforms(to: .image) ? "picture" : "file")
        if (name as NSString).pathExtension.isEmpty { name += "." + (type.preferredFilenameExtension ?? "dat") }
        let target = unique(name)
        try data.write(to: target)
        return target
    }

    /// An image object as a PNG file.
    private static func savePicture(_ provider: NSItemProvider) async throws -> URL {
        let suggested = provider.suggestedName
        let png: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSImage.self) { object, error in
                guard let image = object as? NSImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    continuation.resume(throwing: error ?? Refusal(message: "couldn't add that"))
                    return
                }
                continuation.resume(returning: png)
            }
        }
        let base = suggested.map { ($0 as NSString).deletingPathExtension } ?? "picture"
        let target = unique(base + ".png")
        try png.write(to: target)
        return target
    }

    private static func copy(_ provider: NSItemProvider, type: UTType) async throws -> URL {
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { temporary, error in
                guard let temporary else {
                    continuation.resume(throwing: error ?? Refusal(message: "couldn't add that"))
                    return
                }
                var name = suggested ?? temporary.deletingPathExtension().lastPathComponent
                if (name as NSString).pathExtension.isEmpty {
                    name += "." + (temporary.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "dat") : temporary.pathExtension)
                }
                let target = unique(name)
                do {
                    try FileManager.default.copyItem(at: temporary, to: target)
                    continuation.resume(returning: target)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func download(_ link: URL) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        let (temporary, response) = try await session.download(from: link)
        let name = response.suggestedFilename ?? link.lastPathComponent
        let target = unique(name.isEmpty ? "download" : name)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    /// A free name in the shelf folder: "photo.jpg", then "photo 2.jpg"…
    nonisolated private static func unique(_ name: String) -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "ClickBait/Shelf", directoryHint: .isDirectory)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
