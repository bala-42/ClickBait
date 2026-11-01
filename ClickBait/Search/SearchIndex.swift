import AppKit
import ClickBaitCore
import EventKit
import NaturalLanguage
import OSLog
import Photos
import Vision

/// Smart search's index (`SmartSearch` in Core holds the rules): ClickBait's own notes, facts
/// and saved answers, the quick note, Reminders, Apple Notes, and pictures anywhere in the
/// usual folders (and the Photos library, when allowed), each read once on this Mac and kept
/// with its meaning vector in `~/Library/Application Support/ClickBait/search-index.json`.
/// Files are found through Spotlight at search time. Nothing leaves the Mac.
actor SearchIndex {
    static let shared = SearchIndex()

    private struct Entry: Codable {
        var item: SmartSearch.Item
        var vector: [Float]?
        /// The vector's model ("nomic-embed-text"), so a later model's vectors aren't mixed in.
        var model: String?
    }

    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var refreshing = false
    private var refreshedAt = Date.distantPast

    private let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClickBait/search-index.json")
    }()

    /// At most this many pictures are read (newest first), so the first pass stays minutes, not hours.
    private static let pictureLimit = 3_000

    // MARK: Searching

    func search(_ request: SmartSearch.Request, notchNote: String, photos: Bool) async -> [SmartSearch.Item] {
        load()
        if Date().timeIntervalSince(refreshedAt) > 600 { Task { await refresh(photos: photos) } }
        var pool = entries.values.map { ($0.item, $0.vector) }
        pool.append((SmartSearch.Item(id: "quicknote", kind: .note, title: "Quick note", place: "the notch", text: notchNote), nil))
        // Files: Spotlight's matches for the words, by name or the text inside.
        var boosted: Set<String> = []
        if request.kind == .any || request.kind == .file || request.kind == .image {
            for item in await Self.spotlight(request.terms, images: request.kind == .image) where entries[item.id] == nil {
                pool.append((item, nil))
                boosted.insert(item.id)
            }
        }
        if request.kind != .any { pool = pool.filter { $0.0.kind == request.kind || ($0.0.kind == .file && request.kind == .image) } }
        // Meaning: nomic for the question; items without a nomic vector are embedded now (a few).
        var query = await Embedder.vectors([request.text], as: .query)?.first
        var vectors: [[Float]?] = pool.map(\.1)
        if query != nil {
            let missing = vectors.indices.filter { vectors[$0] == nil }.prefix(64)
            if !missing.isEmpty, let fresh = await Embedder.vectors(missing.map { Self.document(pool[$0].0) }, as: .document) {
                for (index, vector) in zip(missing, fresh) { vectors[index] = vector }
            }
        } else if let apple = NLEmbedding.sentenceEmbedding(for: .english) {
            // No nomic yet (still downloading): Apple's on-device sentence model, same scale.
            query = apple.vector(for: request.text).map { $0.map(Float.init) }
            vectors = pool.map { entry in apple.vector(for: String(Self.document(entry.0).prefix(300))).map { $0.map(Float.init) } }
        }
        let ranked = SmartSearch.rank(zip(pool.map(\.0), vectors).map { ($0, $1) }, for: request, query: query, boosted: boosted)
        Log.ask.notice("Smart search: \(ranked.count, privacy: .public) of \(pool.count, privacy: .public)")
        return ranked
    }

    private static func document(_ item: SmartSearch.Item) -> String {
        "\(item.title). \(item.text)"
    }

    // MARK: Refreshing

    /// Re-reads every source; only new or changed things are embedded and (pictures) looked at.
    func refresh(photos photosOn: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; refreshedAt = Date() }
        load()
        var fresh: [SmartSearch.Item] = []
        fresh += Self.clickBaitNotes()
        fresh += await Self.reminders()
        fresh += await Self.appleNotes()
        var pictures = Self.pictureFiles()
        if photosOn { pictures += Self.libraryPhotos() }
        // Pictures: kept as they were unless the file changed; new ones read with Vision.
        var picturesRead = 0
        for (id, title, place, url, asset, modified) in pictures {
            if let old = entries[id], old.item.modified == modified { fresh.append(old.item); continue }
            guard picturesRead < 400 else { continue }  // a few hundred per pass; the rest next time
            picturesRead += 1
            let text = await Self.look(at: url, asset: asset)
            fresh.append(SmartSearch.Item(id: id, kind: .image, title: title, place: place, text: text,
                                          file: url?.path, modified: modified))
        }
        var next: [String: Entry] = [:]
        for item in fresh {
            if let old = entries[item.id], old.item == item, old.model == Embedder.model {
                next[item.id] = old
            } else {
                next[item.id] = Entry(item: item, vector: nil, model: nil)
            }
        }
        // Embed what's new, 32 at a time; without nomic they wait for the next pass.
        let waiting = next.keys.filter { next[$0]?.vector == nil }
        for batch in stride(from: 0, to: waiting.count, by: 32).map({ Array(waiting[$0..<min($0 + 32, waiting.count)]) }) {
            guard let vectors = await Embedder.vectors(batch.map { Self.document(next[$0]!.item) }, as: .document) else { break }
            for (id, vector) in zip(batch, vectors) { next[id]?.vector = vector; next[id]?.model = Embedder.model }
        }
        entries = next
        save()
        Log.app.notice("Search index: \(next.count, privacy: .public) things, \(picturesRead, privacy: .public) pictures read")
    }

    func forgetAll() {
        entries = [:]
        try? FileManager.default.removeItem(at: file)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Sources

    /// Remembered facts, the notes folder and saved answers.
    private static func clickBaitNotes() -> [SmartSearch.Item] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClickBait")
        var items: [SmartSearch.Item] = []
        if let facts = try? String(contentsOf: base.appendingPathComponent("NOTES.md"), encoding: .utf8) {
            for line in facts.split(separator: "\n") where line.hasPrefix("- ") {
                let fact = String(line.dropFirst(2))
                items.append(.init(id: "fact:\(fact)", kind: .note, title: fact, place: "remembered", text: ""))
            }
        }
        for (folder, place) in [("Notes", "ClickBait notes"), ("answers", "saved answers")] {
            let dir = base.appendingPathComponent(folder)
            for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where url.pathExtension == "md" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                items.append(.init(id: "file:\(url.path)", kind: .note, title: url.deletingPathExtension().lastPathComponent,
                                   place: place, text: String(text.prefix(1_500)), file: url.path, modified: modified))
            }
        }
        return items
    }

    /// Reminders, open and done in the last 90 days, when ClickBait may read them.
    private static func reminders() async -> [SmartSearch.Item] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        let store = EKEventStore()
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date())
        let predicates = [store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil),
                          store.predicateForCompletedReminders(withCompletionDateStarting: since, ending: nil, calendars: nil)]
        var items: [SmartSearch.Item] = []
        for predicate in predicates {
            let found: [(String, String, String, Date?)] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { found in
                    continuation.resume(returning: (found ?? []).map {
                        ($0.calendarItemIdentifier, $0.title ?? "", $0.notes ?? "", $0.dueDateComponents?.date)
                    })
                }
            }
            for (id, title, notes, due) in found where !title.isEmpty {
                let when = due.map { " · due " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
                items.append(.init(id: "reminder:\(id)", kind: .reminder, title: title, place: "Reminders\(when)", text: notes))
            }
        }
        return items
    }

    /// Apple Notes, newest 1,500, read through Notes itself (Automation permission, asked once).
    private static func appleNotes() async -> [SmartSearch.Item] {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") != nil else { return [] }
        let script = """
        set out to ""
        tell application "Notes"
            set n to 0
            repeat with aNote in notes
                set n to n + 1
                if n > 1500 then exit repeat
                set out to out & (id of aNote) & (ASCII character 31) & (name of aNote) & (ASCII character 31) & (plaintext of aNote) & (ASCII character 30)
            end repeat
        end tell
        return out
        """
        let output: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil)
            }
        }
        guard let output else { return [] }
        return output.split(separator: "\u{1E}").compactMap { record in
            let parts = record.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[0].isEmpty else { return nil }
            return .init(id: "applenote:\(parts[0])", kind: .note, title: parts[1], place: "Notes", text: String(parts[2].prefix(1_500)))
        }
    }

    private typealias Picture = (id: String, title: String, place: String, url: URL?, asset: String?, modified: Date?)

    /// Pictures in Desktop, Downloads, Documents, Pictures and the screenshot folder, newest first.
    private static func pictureFiles() -> [Picture] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var folders = ["Desktop", "Downloads", "Documents", "Pictures"].map { home.appendingPathComponent($0) }
        if let shots = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            folders.append(URL(fileURLWithPath: (shots as NSString).expandingTildeInPath))
        }
        let kinds: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"]
        var found: [Picture] = []
        var seen: Set<String> = []
        for folder in folders {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isPackageKey]
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                // Photos' own library is read through PhotoKit, when allowed.
                if url.pathExtension == "photoslibrary" { walker.skipDescendants(); continue }
                guard kinds.contains(url.pathExtension.lowercased()), seen.insert(url.path).inserted else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                found.append(("file:\(url.path)", url.lastPathComponent, url.deletingLastPathComponent().lastPathComponent, url, nil, modified))
            }
        }
        return Array(found.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }.prefix(pictureLimit))
    }

    /// The Photos library's newest pictures, when the user turned it on and allowed it.
    private static func libraryPhotos() -> [Picture] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = pictureLimit
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var found: [Picture] = []
        assets.enumerateObjects { asset, _, _ in
            let day = asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "a photo"
            found.append(("photo:\(asset.localIdentifier)", day, "Photos", nil, asset.localIdentifier, asset.modificationDate))
        }
        return found
    }

    /// What a picture shows and says: Vision's labels and the text in it, on this Mac.
    private static func look(at url: URL?, asset: String?) async -> String {
        let image: CGImage?
        if let url {
            image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else if let asset {
            image = await thumbnail(of: asset)
        } else {
            image = nil
        }
        guard let image else { return "" }
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        try? VNImageRequestHandler(cgImage: image).perform([classify, text])
        let labels = (classify.results ?? []).filter { $0.confidence > 0.3 }.prefix(8).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        let words = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return ([labels.joined(separator: ", ")] + (words.isEmpty ? [] : ["text: " + String(words.prefix(600))])).joined(separator: ". ")
    }

    private static func thumbnail(of id: String) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false
        var result: CGImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 512, height: 512), contentMode: .aspectFit, options: options) { image, _ in
            result = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return result
    }

    /// Files whose name or contents hold the words (Spotlight's own index); AND first, then each word.
    private static func spotlight(_ terms: [String], images: Bool) async -> [SmartSearch.Item] {
        func run(_ query: String) -> [String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", FileManager.default.homeDirectoryForCurrentUser.path, query]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        return await Task.detached(priority: .userInitiated) {
            var paths = run(terms.joined(separator: " "))
            if paths.count < 5 { for term in terms.prefix(3) where term.count > 2 { paths += run(term) } }
            let skip = ["/Library/", "/.Trash/", "/node_modules/", ".app/", "/.git/", "/DerivedData/"]
            let imageKinds: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff"]
            var seen: Set<String> = []
            return paths.filter { path in
                !skip.contains(where: path.contains) && !path.hasSuffix(".app") && seen.insert(path).inserted
                    && (!images || imageKinds.contains((path as NSString).pathExtension.lowercased()))
            }.prefix(40).map { path in
                let url = URL(fileURLWithPath: path)
                let isImage = imageKinds.contains(url.pathExtension.lowercased())
                return SmartSearch.Item(id: "file:\(path)", kind: isImage ? .image : .file, title: url.lastPathComponent,
                                        place: url.deletingLastPathComponent().lastPathComponent, text: "", file: path)
            }
        }.value
    }
}
