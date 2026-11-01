import Foundation

/// Vision Memory: the rules for reading and describing the user's pictures (user's asks,
/// 2026-11-01) — what may be kept, which prompt fits, which folders count, duplicates, and
/// how meaning vectors are stored. Pure.
public enum VisionMemory {
    /// Lines of a picture's text that look secret (passwords, keys, card and ID numbers:
    /// `Memory.looksSecret`) are dropped; `sensitive` says some were.
    public static func guardText(_ text: String) -> (kept: String, sensitive: Bool) {
        var sensitive = false
        let kept = text.split(separator: "\n").filter { line in
            let secret = Memory.looksSecret(String(line))
            if secret { sensitive = true }
            return !secret
        }
        return (kept.joined(separator: "\n"), sensitive)
    }

    /// A screenshot, document, chart or slide rather than a photo: Vision's labels or the name say so.
    public static func isDocumentLike(labels: String, name: String) -> Bool {
        let lower = labels.lowercased()
        let kinds = ["screenshot", "document", "chart", "diagram", "text", "receipt", "menu", "poster", "illustration"]
        return kinds.contains(where: lower.contains) || name.lowercased().hasPrefix("screenshot")
            || name.lowercased().hasPrefix("screen shot")
    }

    /// The brain's prompt. Every caption starts with the kind of picture ("A photo of…", "A
    /// painting of…"): without it nothing told a group photo from a painting of a crowd (1 of
    /// 3,000 captions said "photo", 5 "painting": user's report, 2026-11-01).
    public static func captionPrompt(documentLike: Bool) -> String {
        documentLike
            ? "In one plain sentence of at most 25 words, start with what kind of thing this is (a screenshot, chart, slide, receipt, code, form, web page, diagram…), then its title or subject and its key details. No preamble."
            : "Describe this picture in one plain sentence of at most 22 words. Start with what kind of picture it is (a photo, a painting, a drawing, an illustration, a meme, a render, a scan…), then who or what is in it, what they're doing, where. No preamble."
    }

    /// Which caption style a caption was written in: older ones are redone in the background.
    public static let captionStyle = "kinds-1"

    /// Folders that hold data, not pictures someone would look for: datasets, code
    /// dependencies, build output (2,643 of the user's 3,000 indexed pictures were 16-pixel
    /// digits from a dataset, crowding out their real pictures).
    public static func isDataFolder(_ path: String) -> Bool {
        let parts = Set(path.lowercased().split(separator: "/").map(String.init))
        let data: Set<String> = ["dataset", "datasets", "data", "node_modules", "venv", ".venv", "site-packages", "__pycache__",
                                 "build", "deriveddata", "dist", "checkpoints", "runs", "wandb", "mnist", "cifar", "usps"]
        return !parts.isDisjoint(with: data)
    }

    /// A name that's only digits and separators ("000203.png"): a dataset's or a camera's
    /// frame dump, not a picture someone named.
    public static func isNumberedName(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        return !stem.isEmpty && stem.allSatisfy { $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// Inside one of the folders the user excluded (or the folder itself).
    public static func isExcluded(_ path: String, excluded: [String]) -> Bool {
        excluded.contains { folder in
            let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
            return path == base || path.hasPrefix(base + "/")
        }
    }

    /// Copies (same `contentKey`) become one result, the best-ranked first, with the others'
    /// files in `copies`. Order kept.
    public static func collapseCopies(_ items: [SmartSearch.Item]) -> [SmartSearch.Item] {
        var result: [SmartSearch.Item] = []
        var firstIndex: [String: Int] = [:]
        for item in items {
            guard let key = item.contentKey else { result.append(item); continue }
            if let index = firstIndex[key] {
                if let file = item.file { result[index].copies = (result[index].copies ?? []) + [file] }
            } else {
                firstIndex[key] = result.count
                result.append(item)
            }
        }
        return result
    }

    /// A meaning vector as half-precision bytes (2 per number, 6× smaller than JSON text).
    /// Measured 2026-11-01 on 3,059 items and 10 searches: identical top 5 every time,
    /// largest score change 0.00004.
    public static func pack(_ vector: [Float]) -> Data {
        let halves = vector.map { Float16($0) }
        return halves.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func unpack(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float16>.stride
        return data.withUnsafeBytes { raw in
            (0..<count).map { Float(raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float16>.stride, as: Float16.self)) }
        }
    }
}
