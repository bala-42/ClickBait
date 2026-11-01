import Foundation

/// Where an imported Whisper model's parts are, relative to what the user picked.
public struct SpeechModelLayout: Equatable, Sendable {
    /// "base.en", as in `openai_whisper-base.en`.
    public var variant: String
    /// The folder holding the Core ML bundles (`…/openai_whisper-base.en`).
    public var modelFolder: String
    /// The folder holding `tokenizer.json` and `tokenizer_config.json`.
    public var tokenizerFolder: String

    public init(variant: String, modelFolder: String, tokenizerFolder: String) {
        self.variant = variant
        self.modelFolder = modelFolder
        self.tokenizerFolder = tokenizerFolder
    }
}

public enum SpeechModelImportError: LocalizedError, Equatable, Sendable {
    case noModel
    case unsupported(String)
    case several([String])
    case incomplete(variant: String, missing: [String])
    case noTokenizer(String)
    case badTokenizer

    public var errorDescription: String? {
        switch self {
        case .noModel:
            "That isn't a speech model: no “openai_whisper-…” folder inside. Choose the SpeechModels folder (or a .zip of it) from a Mac where ClickBait downloaded the model."
        case .unsupported(let variant):
            "That's the “\(variant)” model; ClickBait uses tiny.en, base.en, small.en or Large Turbo."
        case .several(let variants):
            "That holds several models (\(variants.joined(separator: ", "))). Pick one in Settings → Speech recognition first, then import again."
        case .incomplete(let variant, let missing):
            "The \(variant) model is incomplete: \(missing.joined(separator: ", ")) missing. Copy the whole folder again."
        case .noTokenizer(let variant):
            "The \(variant) model's tokenizer is missing (models/openai/\(SpeechModelImport.tokenizerName(for: variant))/tokenizer.json). Import the whole SpeechModels folder, not just the model inside it."
        case .badTokenizer:
            "The tokenizer file is damaged. Copy the folder again."
        }
    }
}

/// Checks a Whisper model the user imports from a folder or .zip (no network: a Mac
/// offline can finish setup) and says where it goes. Works on a listing of relative paths
/// so it's testable without the disk; `listing(of:)` makes one.
public enum SpeechModelImport {
    static let modelPrefix = "openai_whisper-"

    /// The tokenizer's folder name: Large v3's variants ("large-v3-v20240930_turbo_632MB")
    /// share `whisper-large-v3`'s; the others have their own.
    public static func tokenizerName(for variant: String) -> String {
        variant.hasPrefix("large-v3") ? "whisper-large-v3" : "whisper-\(variant)"
    }
    /// What WhisperKit loads, as the download leaves it.
    public static let modelParts = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc",
                                    "config.json", "generation_config.json"]
    /// Every compiled Core ML bundle has this; a half-copied one often doesn't.
    static let bundleMarker = "coremldata.bin"
    public static let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]

    /// Where the download puts a variant's parts, under the speech models folder.
    public static func destination(for variant: String) -> (model: String, tokenizer: String) {
        ("models/argmaxinc/whisperkit-coreml/\(modelPrefix)\(variant)", "models/openai/\(tokenizerName(for: variant))")
    }

    /// `paths`: files and folders, "/"-separated, relative to the picked item's parent (so
    /// the picked folder's own name is the first component). `variants`: those ClickBait
    /// offers; `preferred`: the one selected, chosen when several are present.
    public static func inspect(_ paths: Set<String>, variants: [String],
                               preferred: String?) -> Result<SpeechModelLayout, SpeechModelImportError> {
        let found = paths.compactMap { path -> (variant: String, folder: String)? in
            let name = path.split(separator: "/").last.map(String.init) ?? path
            guard name.hasPrefix(modelPrefix), name.count > modelPrefix.count else { return nil }
            return (String(name.dropFirst(modelPrefix.count)), path)
        }.sorted { $0.folder < $1.folder }
        guard !found.isEmpty else { return .failure(.noModel) }

        let supported = found.filter { variants.contains($0.variant) }
        let distinct = Array(Set(supported.map(\.variant))).sorted()
        let chosen: (variant: String, folder: String)
        if let preferred, let match = supported.first(where: { $0.variant == preferred }) {
            chosen = match
        } else if distinct.count == 1, let only = supported.first {
            chosen = only
        } else if distinct.count > 1 {
            return .failure(.several(distinct))
        } else {
            return .failure(.unsupported(found[0].variant))
        }

        let missing = modelParts.filter { part in
            let path = chosen.folder + "/" + part
            guard paths.contains(path) else { return true }
            return part.hasSuffix(".mlmodelc") && !paths.contains(path + "/" + bundleMarker)
        }
        guard missing.isEmpty else { return .failure(.incomplete(variant: chosen.variant, missing: missing)) }

        guard let tokenizer = tokenizerFolder(for: chosen.variant, model: chosen.folder, in: paths) else {
            return .failure(.noTokenizer(chosen.variant))
        }
        return .success(SpeechModelLayout(variant: chosen.variant, modelFolder: chosen.folder, tokenizerFolder: tokenizer))
    }

    /// The download's own place (`…/whisper-<variant>`) first, then beside the model files,
    /// then the one folder anywhere that has both tokenizer files.
    static func tokenizerFolder(for variant: String, model: String, in paths: Set<String>) -> String? {
        func complete(_ folder: String) -> Bool {
            tokenizerFiles.allSatisfy { paths.contains(folder + "/" + $0) }
        }
        let folders = Set(paths.compactMap { path -> String? in
            guard path.hasSuffix("/tokenizer.json") else { return nil }
            return String(path.dropLast("/tokenizer.json".count))
        }).filter(complete).sorted()
        if let own = folders.first(where: { $0.hasSuffix("/" + tokenizerName(for: variant)) || $0 == tokenizerName(for: variant) }) { return own }
        if folders.contains(model) { return model }
        return folders.count == 1 ? folders[0] : nil
    }

    /// A real tokenizer.json is a JSON object with a "model" (its vocabulary).
    public static func isTokenizer(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["model"] is [String: Any]
    }

    /// Relative paths of everything under `root`, starting with its own name. Doesn't look
    /// inside Core ML bundles past their top level, or into hidden folders (`.cache`).
    public static func listing(of root: URL, maxDepth: Int = 8) -> Set<String> {
        var paths: Set<String> = [root.lastPathComponent]
        func walk(_ folder: URL, prefix: String, depth: Int) {
            guard depth < maxDepth,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for child in children {
                let path = prefix + "/" + child.lastPathComponent
                paths.insert(path)
                let isFolder = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isFolder else { continue }
                if prefix.hasSuffix(".mlmodelc") { continue }
                walk(child, prefix: path, depth: depth + 1)
            }
        }
        walk(root, prefix: root.lastPathComponent, depth: 0)
        return paths
    }

    /// Unzips (with macOS's own `ditto`, offline), checks, and copies a picked folder or .zip
    /// into `base` (the speech models folder), laid out as the download leaves it. Returns
    /// the imported variant ("base.en"). Blocking: call off the main thread.
    /// Windows shell: `ditto` is macOS-only.
    public static func install(from source: URL, into base: URL, variants: [String], preferred: String?) throws -> String {
        let files = FileManager.default
        var root = source
        var unzipped: URL?
        defer { if let unzipped { try? files.removeItem(at: unzipped) } }
        if source.pathExtension.lowercased() == "zip" {
            let folder = files.temporaryDirectory.appending(path: "ClickBait-import-\(UUID().uuidString)", directoryHint: .isDirectory)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            unzipped = folder
            try unzip(source, into: folder)
            root = folder
        }
        let layout = try inspect(listing(of: root), variants: variants, preferred: preferred).get()
        let parent = root.deletingLastPathComponent()
        let modelSource = parent.appending(path: layout.modelFolder, directoryHint: .isDirectory)
        let tokenizerSource = parent.appending(path: layout.tokenizerFolder, directoryHint: .isDirectory)
        guard let tokenizer = try? Data(contentsOf: tokenizerSource.appending(path: "tokenizer.json")),
              isTokenizer(tokenizer) else { throw SpeechModelImportError.badTokenizer }

        let place = destination(for: layout.variant)
        try replace(base.appending(path: place.model, directoryHint: .isDirectory), with: modelSource, only: nil)
        try replace(base.appending(path: place.tokenizer, directoryHint: .isDirectory), with: tokenizerSource,
                    only: tokenizerFiles + ["config.json"])
        return layout.variant
    }

    /// Copies `source` (or just the `only` files in it) next to `target`, then swaps it in,
    /// so a failed copy leaves a model that's already there alone. Picking the folder that's
    /// already in place copies nothing.
    private static func replace(_ target: URL, with source: URL, only names: [String]?) throws {
        let files = FileManager.default
        guard source.resolvingSymlinksInPath().standardizedFileURL != target.resolvingSymlinksInPath().standardizedFileURL else { return }
        let parent = target.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".\(target.lastPathComponent)-importing", directoryHint: .isDirectory)
        try? files.removeItem(at: staging)
        if let names {
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in names where files.fileExists(atPath: source.appending(path: name).path) {
                try files.copyItem(at: source.appending(path: name), to: staging.appending(path: name))
            }
        } else {
            try files.copyItem(at: source, to: staging)
        }
        if files.fileExists(atPath: target.path) {
            _ = try files.replaceItemAt(target, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: target)
        }
    }

    private static func unzip(_ archive: URL, into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Couldn't open that .zip."])
        }
    }
}
