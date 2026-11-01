import AppKit
import ClickBaitCore
import CryptoKit
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

        init(item: SmartSearch.Item, vector: [Float]?, model: String?) {
            (self.item, self.vector, self.model) = (item, vector, model)
        }

        // On disk the vector is half-precision bytes (`VisionMemory.pack`, ~2 KB as base64
        // instead of ~9 KB of JSON numbers); older files' number lists still load.
        enum CodingKeys: String, CodingKey { case item, packed, vector, model }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            item = try container.decode(SmartSearch.Item.self, forKey: .item)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            if let packed = try container.decodeIfPresent(Data.self, forKey: .packed) {
                vector = VisionMemory.unpack(packed)
            } else {
                vector = try container.decodeIfPresent([Float].self, forKey: .vector)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(item, forKey: .item)
            try container.encodeIfPresent(model, forKey: .model)
            try container.encodeIfPresent(vector.map(VisionMemory.pack), forKey: .packed)
        }
    }

    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var refreshing = false
    private var refreshedAt = Date.distantPast

    private let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClickBait/search-index.json")
    }()
    /// Pictures the user chose Forget for: never read again (their ids, as a JSON list).
    private let forgottenFile: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClickBait/vision-forgotten.json")
    }()
    private var forgotten: Set<String> = []
    /// Captions written in the pass under way (saved at its end), so Settings' count moves live.
    private var describingNow = 0
    private var describing = false

    /// At most this many pictures are read (newest first), so the first pass stays minutes, not hours.
    private static let pictureLimit = 3_000

    // MARK: Searching

    func search(_ request: SmartSearch.Request, notchNote: String, options: VisionOptions) async -> [SmartSearch.Item] {
        load()
        let request = await Self.withRelatedWords(request, brain: options.brain)
        if Date().timeIntervalSince(refreshedAt) > 600 { Task { await refresh(options) } }
        var pool = entries.values.filter { entry in
            entry.item.file.map { !VisionMemory.isExcluded($0, excluded: options.excluded) } ?? true
        }.map { ($0.item, $0.vector) }
        pool.append((SmartSearch.Item(id: "quicknote", kind: .note, title: "Quick note", place: "the notch", text: notchNote), nil))
        // Files: Spotlight's matches for the words, by name or the text inside.
        var boosted: Set<String> = []
        if request.kind == .any || request.kind == .file || request.kind == .image {
            for item in await Self.spotlight(request.terms, images: request.kind == .image)
            where entries[item.id] == nil && !forgotten.contains(item.id) && !VisionMemory.isExcluded(item.file ?? "", excluded: options.excluded) {
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
        let candidates = SmartSearch.rank(zip(pool.map(\.0), vectors).map { ($0, $1) }, for: request, query: query,
                                          boosted: boosted, limit: 30)
        // A file deleted or moved since it was read never shows; copies become one result.
        let present = candidates.filter { item in item.file.map { FileManager.default.fileExists(atPath: $0) } ?? true }
        let ranked = Array(VisionMemory.collapseCopies(present).prefix(8))
        Log.ask.notice("Smart search: \(ranked.count, privacy: .public) of \(pool.count, privacy: .public)")
        return ranked
    }

    /// The brain's related words for the search (~0.3 s); the search goes on without them
    /// after 2 s or if the brain isn't there.
    private static func withRelatedWords(_ request: SmartSearch.Request, brain: String) async -> SmartSearch.Request {
        var call = URLRequest(url: OllamaProvider.baseURL.appending(path: "api/generate"), timeoutInterval: 2)
        call.httpMethod = "POST"
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": brain, "prompt": request.relatedPrompt, "stream": false, "think": false,
            "options": ["temperature": 0, "num_predict": 40]
        ] as [String: Any])
        guard let (data, response) = try? await URLSession.shared.data(for: call),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reply = json["response"] as? String else { return request }
        return request.with(related: reply)
    }

    private static func document(_ item: SmartSearch.Item) -> String {
        item.searchable
    }

    // MARK: Refreshing

    /// Re-reads every source; only new or changed things are embedded and (pictures) looked at.
    /// `quick` (a folder changed): pictures only, no captions; the rest is kept as it was.
    func refresh(_ options: VisionOptions, quick: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; if !quick { refreshedAt = Date() } }
        load()
        var fresh: [SmartSearch.Item] = []
        if quick {
            fresh += entries.values.map(\.item).filter { $0.kind != .image }
        } else {
            fresh += Self.clickBaitNotes()
            fresh += await Self.reminders()
            fresh += await Self.appleNotes()
        }
        var pictures = Self.pictureFiles(folders: options.folders, excluded: options.excluded)
        if options.photos { pictures += Self.libraryPhotos() }
        pictures = pictures.filter { !forgotten.contains($0.id) }
        // Pictures: kept as they were unless the file changed; new ones read with Vision when
        // the Mac allows (`VisionOptions.mayWork`). Copies (same contents) reuse what was read.
        var picturesRead = 0
        let you = YourFace.reference()
        var byContent: [String: SmartSearch.Item] = [:]
        for entry in entries.values where entry.item.kind == .image { if let key = entry.item.contentKey { byContent[key] = entry.item } }
        for (id, title, place, url, asset, modified) in pictures {
            if let old = entries[id], old.item.modified == modified {
                // Read before copies were spotted: fingerprinted now (64 KB, no Vision).
                var kept = old.item
                if kept.contentKey == nil, let url {
                    kept.contentKey = Self.contentKey(url, bytes: kept.bytes ?? (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize)
                    if let key = kept.contentKey, byContent[key] == nil { byContent[key] = kept }
                }
                fresh.append(kept)
                continue
            }
            let bytes = url.flatMap { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
            let key = url.flatMap { Self.contentKey($0, bytes: bytes) }
            var item = SmartSearch.Item(id: id, kind: .image, title: title, place: place, text: "",
                                        file: url?.path, modified: modified, bytes: bytes)
            item.contentKey = key
            if let key, let twin = byContent[key] {
                (item.text, item.caption, item.hasYou, item.sensitive) = (twin.text, twin.caption, twin.hasYou, twin.sensitive)
                (item.userEdited, item.captionModel) = (twin.userEdited, twin.captionModel)
                fresh.append(item)
                continue
            }
            guard picturesRead < 400, options.mayWork else { continue }  // a few hundred per pass; the rest next time
            picturesRead += 1
            let look = await Self.look(at: url, asset: asset, you: you, screenshots: options.screenshots, name: title)
            (item.text, item.sensitive) = (look.text, look.sensitive ? true : nil)
            item.hasYou = you == nil ? nil : look.hasYou
            if let key { byContent[key] = item }
            fresh.append(item)
        }
        // Captions from the brain (it can see pictures): newest first, a few per pass, only
        // while the Mac allows; then pictures a different brain described. Never the user's own
        // captions, sensitive pictures, or (switched off) screenshots and documents.
        var captioned = 0
        if !quick {
            let waiting = fresh.indices.filter { index in
                let item = fresh[index]
                guard item.kind == .image, item.userEdited != true, item.sensitive != true else { return false }
                if !options.screenshots, VisionMemory.isDocumentLike(labels: item.text, name: item.title) { return false }
                // Captions from before brains were recorded count as the current brain's.
                return item.caption == nil || (item.captionModel ?? options.brain) != options.brain
            }
            let ordered = waiting.filter { fresh[$0].caption == nil } + waiting.filter { fresh[$0].caption != nil }
            var described: [String: (String, String)] = [:]
            for index in ordered {
                guard captioned < Self.captionsPerPass, !Task.isCancelled, options.mayWork else { break }
                if let key = fresh[index].contentKey, let done = described[key] {
                    (fresh[index].caption, fresh[index].captionModel) = (done.0, done.1)
                    continue
                }
                describing = true
                guard let caption = await Self.caption(fresh[index], brain: options.brain) else { continue }
                (fresh[index].caption, fresh[index].captionModel) = (caption, options.brain)
                describingNow += 1
                if let key = fresh[index].contentKey { described[key] = (caption, options.brain) }
                captioned += 1
            }
        }
        var next: [String: Entry] = [:]
        for item in fresh {
            // The vector depends only on the searchable text: kept when that's the same.
            if var old = entries[item.id], old.item.searchable == item.searchable, old.model == Embedder.model {
                old.item = item
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
        (describingNow, describing) = (0, false)
        save()
        Log.app.notice("Search index: \(next.count, privacy: .public) things, \(picturesRead, privacy: .public) pictures read, \(captioned, privacy: .public) captioned")
    }

    /// Forget this picture: out of the index, never read again.
    func forget(_ id: String) {
        load()
        forgotten.insert(id)
        entries[id] = nil
        save()
    }

    /// The user's own description: kept over the brain's, searched by meaning at once.
    func setCaption(_ id: String, _ caption: String) async {
        load()
        guard var entry = entries[id] else { return }
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.item.caption = text.isEmpty ? nil : text
        entry.item.userEdited = text.isEmpty ? nil : true
        entry.vector = await Embedder.vectors([Self.document(entry.item)], as: .document)?.first
        entry.model = entry.vector == nil ? nil : Embedder.model
        entries[id] = entry
        save()
    }

    /// For Settings: pictures known, described (counting this pass's so far), the index's
    /// size on disk, and whether pictures are being described right now.
    func stats() -> (pictures: Int, described: Int, bytes: Int, active: Bool) {
        load()
        let pictures = entries.values.filter { $0.item.kind == .image }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let described = min(pictures.count, pictures.filter { $0.item.caption != nil }.count + describingNow)
        return (pictures.count, described, size, describing)
    }

    /// Size and a hash of the first 64 KB: the same for copies of one file.
    private static func contentKey(_ url: URL, bytes: Int?) -> String? {
        guard let bytes, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 65_536) else { return nil }
        let digest = SHA256.hash(data: head).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(bytes)-\(digest)"
    }

    /// Pictures read again (after the user's reference photo changed): faces are matched anew.
    func forgetPictures() {
        load()
        entries = entries.filter { $0.value.item.kind != .image }
        save()
    }

    /// ~0.5 s each with gemma4:e4b (measured 2026-11-01); 300 every 30 minutes covers 3,000 pictures in 5 hours of use.
    private static let captionsPerPass = 300

    /// One line on what a picture shows, from the brain, or nil (no brain, can't see, slow).
    private static func caption(_ item: SmartSearch.Item, brain: String) async -> String? {
        let prompt = VisionMemory.captionPrompt(documentLike: VisionMemory.isDocumentLike(labels: item.text, name: item.title))
        let image: CGImage?
        if let path = item.file {
            image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else if item.id.hasPrefix("photo:") {
            image = await thumbnail(of: String(item.id.dropFirst(6)))
        } else {
            image = nil
        }
        guard let image, let jpeg = jpeg(image, longSide: 512) else { return nil }
        var call = URLRequest(url: OllamaProvider.baseURL.appending(path: "api/generate"), timeoutInterval: 45)
        call.httpMethod = "POST"
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": brain, "stream": false, "think": false, "images": [jpeg.base64EncodedString()],
            "prompt": prompt,
            "options": ["temperature": 0, "num_predict": 48]
        ] as [String: Any])
        guard let (data, response) = try? await URLSession.shared.data(for: call),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reply = (json["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else { return nil }
        return String(reply.prefix(200))
    }

    private static func jpeg(_ image: CGImage, longSide: CGFloat) -> Data? {
        let scale = min(1, longSide / CGFloat(max(image.width, image.height)))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let small = NSImage(size: size)
        small.lockFocus()
        NSImage(cgImage: image, size: .zero).draw(in: NSRect(origin: .zero, size: size))
        small.unlockFocus()
        guard let tiff = small.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    func forgetAll() {
        entries = [:]
        refreshedAt = Date()  // no instant rebuild behind the user's back; the next pass reads again
        try? FileManager.default.removeItem(at: file)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: forgottenFile), let ids = try? JSONDecoder().decode([String].self, from: data) {
            forgotten = Set(ids)
        }
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        if let ids = try? JSONEncoder().encode(Array(forgotten)) { try? ids.write(to: forgottenFile, options: .atomic) }
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
    private static func pictureFiles(folders paths: [String], excluded: [String]) -> [Picture] {
        let folders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
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
                // The user's excluded folders: never looked inside.
                if VisionMemory.isExcluded(url.path, excluded: excluded) { walker.skipDescendants(); continue }
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
    private static func look(at url: URL?, asset: String?, you: VNFeaturePrintObservation?, screenshots: Bool,
                             name: String) async -> (text: String, hasYou: Bool, sensitive: Bool) {
        let image: CGImage?
        if let url {
            image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else if let asset {
            image = await thumbnail(of: asset)
        } else {
            image = nil
        }
        guard let image else { return ("", false, false) }
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform(you == nil ? [classify, text] : [classify, text, faces])
        let hasYou = you.map { reference in
            (faces.results ?? []).contains { YourFace.matches(reference, face: $0, in: image) }
        } ?? false
        let labels = (classify.results ?? []).filter { $0.confidence > 0.3 }.prefix(8).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        let labelText = labels.joined(separator: ", ")
        // Screenshots and documents switched off: only that it is one, nothing it says.
        if !screenshots, VisionMemory.isDocumentLike(labels: labelText, name: name) {
            return (labelText, hasYou, false)
        }
        // Secret-looking lines (passwords, card and ID numbers) are never kept.
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let guarded = VisionMemory.guardText(lines)
        let words = guarded.kept.replacingOccurrences(of: "\n", with: " ")
        return (([labelText] + (words.isEmpty ? [] : ["text: " + String(words.prefix(600))])).joined(separator: ". "), hasYou, guarded.sensitive)
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
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return SmartSearch.Item(id: "file:\(path)", kind: isImage ? .image : .file, title: url.lastPathComponent,
                                        place: url.deletingLastPathComponent().lastPathComponent, text: "", file: path,
                                        modified: values?.contentModificationDate, bytes: values?.fileSize)
            }
        }.value
    }
}
