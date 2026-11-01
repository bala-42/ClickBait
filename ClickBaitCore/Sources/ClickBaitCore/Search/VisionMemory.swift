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
    public static func captionPrompt(documentLike: Bool, video: Bool = false) -> String {
        if video {
            return "These are three moments from one video, in order. In one plain sentence of at most 22 words, start with \"A video of\", then who or what is in it, what's happening, where. Describe only what is clearly visible in the frames; don't guess. People are often seen from behind or only partly: arms, hands or a head of hair belong to a person, not a doll or mannequin, unless it is clearly a toy. If something is being done to someone (hair washed, cut or styled, makeup put on), say whether they do it themselves or another person does it to them. No preamble."
        }
        return documentLike
            ? "In one plain sentence of at most 25 words, start with what kind of thing this is (a screenshot, chart, slide, receipt, code, form, web page, diagram…), then its title or subject and its key details. No preamble."
            : "Describe this picture in one plain sentence of at most 22 words. Start with what kind of picture it is (a photo, a painting, a drawing, an illustration, a meme, a render, a scan…), then who or what is in it, what they're doing, where. No preamble."
    }

    /// Which caption style a caption was written in: older ones are redone in the background.
    public static let captionStyle = "kinds-1"
    /// Videos' own style: "frames3-1", described from three moments (`SearchIndex.threeFrames`).
    public static let videoCaptionStyle = "frames3-2"

    /// Folders that hold data, not pictures someone would look for: datasets, code
    /// dependencies, build output (2,643 of the user's 3,000 indexed pictures were 16-pixel
    /// digits from a dataset, crowding out their real pictures).
    public static func isDataFolder(_ path: String) -> Bool {
        let parts = Set(path.lowercased().split(separator: "/").map(String.init))
        let data: Set<String> = ["dataset", "datasets", "data", "node_modules", "venv", ".venv", "site-packages", "__pycache__",
                                 "build", "deriveddata", "dist", "checkpoints", "runs", "wandb", "mnist", "cifar", "usps"]
        if !parts.isDisjoint(with: data) { return true }
        // A machine-learning project's folders, alone or joined by _ or - ("train", "masks_test",
        // "extracted_frames"): 2,700 training images and masks were described as pictures
        // (user's report, 2026-11-02). Names with spaces ("Test photos") are people's, kept.
        let mlWords: Set<String> = ["train", "training", "test", "val", "valid", "validation", "masks", "mask", "labels",
                                    "annotations", "samples", "frames", "predictions", "preds", "outputs", "logs"]
        // Folders only: a file's own name ("test_photo.jpg") doesn't make it data.
        var folders = path.lowercased().split(separator: "/").map(String.init)
        if folders.last?.contains(".") == true { folders.removeLast() }
        return folders.contains { part in
            !part.contains(" ") && part.split(whereSeparator: { $0 == "_" || $0 == "-" }).contains { mlWords.contains(String($0)) }
        }
    }

    /// A machine-made name, not one someone gave a picture: only digits and separators
    /// ("000203.png"), a hash ("001024887930487182779f5df682a657.png"), or a number and a word
    /// ("100_predict.png"). Many in one folder make a dump (`SearchIndex.pictureFiles`).
    public static func isNumberedName(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        guard !stem.isEmpty else { return false }
        if stem.allSatisfy({ $0.isNumber || $0 == "_" || $0 == "-" }) { return true }
        if stem.count >= 16, stem.allSatisfy(\.isHexDigit) { return true }
        return stem.range(of: #"^\d+[_-][a-z]+$"#, options: .regularExpression) != nil
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
            // Same contents, or versions of one file: ClickBait's smaller copies and conversions
            // ("x (smaller).mov", "x (smaller) 2.mov", "x.gif" with "x.MP4") — they filled a
            // search, 2026-11-02. Either key joins the result already listed.
            let keys = [item.contentKey.map { "content:" + $0 }, variantKey(item.file)].compactMap { $0 }
            if let index = keys.lazy.compactMap({ firstIndex[$0] }).first {
                if let file = item.file { result[index].copies = (result[index].copies ?? []) + [file] }
                for key in keys { firstIndex[key] = index }
            } else {
                for key in keys { firstIndex[key] = result.count }
                result.append(item)
            }
        }
        return result
    }

    /// Folder and name without its extension and ClickBait's " (smaller)" and copy number:
    /// "…/shampoo_input (12) (smaller) 2.mov" and "…/shampoo_input (12).MP4" →
    /// "…/shampoo_input (12)". Videos and pictures only (a report's .docx and .pdf stay apart).
    public static func variantKey(_ path: String?) -> String? {
        guard let path, SmartSearch.Kind.of(path).isVisual else { return nil }
        var stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let range = stem.range(of: #"( \(smaller\))+( \d+)?$"#, options: .regularExpression) { stem = String(stem[..<range.lowerBound]) }
        return "variant:" + (path as NSString).deletingLastPathComponent.lowercased() + "/" + stem.lowercased()
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
