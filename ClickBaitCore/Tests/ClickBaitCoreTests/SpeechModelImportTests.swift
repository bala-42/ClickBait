import Foundation
import Testing
@testable import ClickBaitCore

struct SpeechModelImportTests {
    private let variants = ["tiny.en", "base.en", "small.en"]

    /// What the download leaves under the speech models folder, for one variant.
    private func downloaded(_ variant: String, root: String = "SpeechModels") -> Set<String> {
        let model = "\(root)/models/argmaxinc/whisperkit-coreml/openai_whisper-\(variant)"
        let tokenizer = "\(root)/models/openai/whisper-\(variant)"
        var paths: Set<String> = [root, "\(root)/models", model, tokenizer,
                                  "\(model)/config.json", "\(model)/generation_config.json",
                                  "\(tokenizer)/tokenizer.json", "\(tokenizer)/tokenizer_config.json", "\(tokenizer)/config.json"]
        for bundle in ["AudioEncoder", "MelSpectrogram", "TextDecoder"] {
            paths.insert("\(model)/\(bundle).mlmodelc")
            paths.insert("\(model)/\(bundle).mlmodelc/coremldata.bin")
        }
        return paths
    }

    @Test func acceptsTheDownloadedFolder() {
        let result = SpeechModelImport.inspect(downloaded("base.en"), variants: variants, preferred: "base.en")
        #expect(result == .success(SpeechModelLayout(
            variant: "base.en",
            modelFolder: "SpeechModels/models/argmaxinc/whisperkit-coreml/openai_whisper-base.en",
            tokenizerFolder: "SpeechModels/models/openai/whisper-base.en")))
    }

    @Test func importsWhicheverSupportedModelItHolds() {
        let result = SpeechModelImport.inspect(downloaded("small.en"), variants: variants, preferred: "base.en")
        #expect((try? result.get())?.variant == "small.en")
    }

    @Test func picksTheSelectedModelWhenThereAreSeveral() {
        let both = downloaded("tiny.en").union(downloaded("small.en"))
        #expect((try? SpeechModelImport.inspect(both, variants: variants, preferred: "small.en").get())?.variant == "small.en")
        #expect(SpeechModelImport.inspect(both, variants: variants, preferred: "base.en") == .failure(.several(["small.en", "tiny.en"])))
    }

    @Test func aFolderWithoutAModelIsRefused() {
        #expect(SpeechModelImport.inspect(["Photos", "Photos/cat.jpg"], variants: variants, preferred: nil) == .failure(.noModel))
    }

    @Test func otherWhisperModelsAreRefused() {
        let paths: Set<String> = ["m", "m/openai_whisper-large-v3"]
        #expect(SpeechModelImport.inspect(paths, variants: variants, preferred: nil) == .failure(.unsupported("large-v3")))
    }

    @Test func missingAndHalfCopiedPartsAreNamed() {
        var paths = downloaded("base.en")
        let model = "SpeechModels/models/argmaxinc/whisperkit-coreml/openai_whisper-base.en"
        paths.remove("\(model)/TextDecoder.mlmodelc")
        paths.remove("\(model)/TextDecoder.mlmodelc/coremldata.bin")
        paths.remove("\(model)/AudioEncoder.mlmodelc/coremldata.bin")
        paths.remove("\(model)/generation_config.json")
        #expect(SpeechModelImport.inspect(paths, variants: variants, preferred: nil) == .failure(.incomplete(
            variant: "base.en", missing: ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "generation_config.json"])))
    }

    @Test func theModelFolderAloneHasNoTokenizer() {
        let only = Set(downloaded("base.en").filter { $0.contains("argmaxinc") }.map {
            String($0.dropFirst("SpeechModels/models/argmaxinc/whisperkit-coreml/".count))
        })
        #expect(SpeechModelImport.inspect(only, variants: variants, preferred: nil) == .failure(.noTokenizer("base.en")))
    }

    @Test func aTokenizerBesideTheModelFilesIsFound() {
        var paths = Set(downloaded("base.en").filter { $0.contains("argmaxinc") }.map {
            String($0.dropFirst("SpeechModels/models/argmaxinc/whisperkit-coreml/".count))
        })
        paths.insert("openai_whisper-base.en/tokenizer.json")
        paths.insert("openai_whisper-base.en/tokenizer_config.json")
        #expect((try? SpeechModelImport.inspect(paths, variants: variants, preferred: nil).get())?.tokenizerFolder
                == "openai_whisper-base.en")
    }

    @Test func aTokenizerNeedsBothFiles() {
        var paths = downloaded("base.en")
        paths.remove("SpeechModels/models/openai/whisper-base.en/tokenizer_config.json")
        #expect(SpeechModelImport.inspect(paths, variants: variants, preferred: nil) == .failure(.noTokenizer("base.en")))
    }

    @Test func goesWhereTheDownloadPutsIt() {
        let destination = SpeechModelImport.destination(for: "tiny.en")
        #expect(destination.model == "models/argmaxinc/whisperkit-coreml/openai_whisper-tiny.en")
        #expect(destination.tokenizer == "models/openai/whisper-tiny.en")
    }

    @Test func recognisesARealTokenizer() {
        #expect(SpeechModelImport.isTokenizer(Data(#"{"version":"1.0","model":{"type":"BPE","vocab":{}}}"#.utf8)))
        #expect(!SpeechModelImport.isTokenizer(Data(#"{"version":"1.0"}"#.utf8)))
        #expect(!SpeechModelImport.isTokenizer(Data("not json".utf8)))
    }

    @Test func listsAFolderOnDiskWithoutGoingDeepIntoBundles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SpeechModelImportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appending(path: "openai_whisper-base.en/AudioEncoder.mlmodelc/weights")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data().write(to: bundle.appending(path: "weight.bin"))
        try Data().write(to: bundle.deletingLastPathComponent().appending(path: "coremldata.bin"))
        try FileManager.default.createDirectory(at: root.appending(path: ".cache/huggingface"), withIntermediateDirectories: true)

        let name = root.lastPathComponent
        let paths = SpeechModelImport.listing(of: root)
        #expect(paths.contains("\(name)/openai_whisper-base.en/AudioEncoder.mlmodelc/coremldata.bin"))
        #expect(paths.contains("\(name)/openai_whisper-base.en/AudioEncoder.mlmodelc/weights"))
        #expect(!paths.contains("\(name)/openai_whisper-base.en/AudioEncoder.mlmodelc/weights/weight.bin"))
        #expect(!paths.contains { $0.contains(".cache") })
    }
}

/// A real folder: `CLICKBAIT_LIVE_SPEECH_FOLDER=~/Library/Application\ Support/ClickBait/SpeechModels swift test …`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_SPEECH_FOLDER"] != nil))
struct LiveSpeechModelImportTests {
    @Test func acceptsARealDownloadedFolder() throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_SPEECH_FOLDER"]))
        let start = ContinuousClock.now
        let paths = SpeechModelImport.listing(of: folder)
        let layout = try SpeechModelImport.inspect(paths, variants: ["tiny.en", "base.en", "small.en"], preferred: nil).get()
        print("\(paths.count) paths in \(ContinuousClock.now - start): \(layout)")
        let tokenizer = folder.deletingLastPathComponent().appending(path: layout.tokenizerFolder + "/tokenizer.json")
        #expect(SpeechModelImport.isTokenizer(try Data(contentsOf: tokenizer)))
    }
}

/// The whole import on disk: a fake model laid out like the download, into a fake base.
struct SpeechModelInstallTests {
    private let variants = ["tiny.en", "base.en", "small.en"]
    private let files = FileManager.default

    private func scratch() throws -> URL {
        let folder = files.temporaryDirectory.appending(path: "SpeechModelInstallTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `<parent>/SpeechModels/models/…` as the download leaves it.
    @discardableResult
    private func makeDownloaded(_ variant: String, in parent: URL, tokenizer: String = #"{"model":{"type":"BPE"}}"#) throws -> URL {
        let root = parent.appending(path: "SpeechModels", directoryHint: .isDirectory)
        let place = SpeechModelImport.destination(for: variant)
        let model = root.appending(path: place.model, directoryHint: .isDirectory)
        for bundle in ["AudioEncoder", "MelSpectrogram", "TextDecoder"] {
            let folder = model.appending(path: "\(bundle).mlmodelc/weights", directoryHint: .isDirectory)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("w".utf8).write(to: folder.appending(path: "weight.bin"))
            try Data("c".utf8).write(to: folder.deletingLastPathComponent().appending(path: "coremldata.bin"))
        }
        try Data("{}".utf8).write(to: model.appending(path: "config.json"))
        try Data("{}".utf8).write(to: model.appending(path: "generation_config.json"))
        let tokenizerFolder = root.appending(path: place.tokenizer, directoryHint: .isDirectory)
        try files.createDirectory(at: tokenizerFolder, withIntermediateDirectories: true)
        try Data(tokenizer.utf8).write(to: tokenizerFolder.appending(path: "tokenizer.json"))
        try Data("{}".utf8).write(to: tokenizerFolder.appending(path: "tokenizer_config.json"))
        return root
    }

    private func installed(_ variant: String, in base: URL) -> Bool {
        let place = SpeechModelImport.destination(for: variant)
        return files.fileExists(atPath: base.appending(path: place.model + "/TextDecoder.mlmodelc/weights/weight.bin").path)
            && files.fileExists(atPath: base.appending(path: place.tokenizer + "/tokenizer.json").path)
            && files.fileExists(atPath: base.appending(path: place.tokenizer + "/tokenizer_config.json").path)
    }

    @Test func installsAFolder() throws {
        let work = try scratch()
        defer { try? files.removeItem(at: work) }
        let source = try makeDownloaded("base.en", in: work.appending(path: "other-mac"))
        let base = work.appending(path: "base", directoryHint: .isDirectory)
        #expect(try SpeechModelImport.install(from: source, into: base, variants: variants, preferred: nil) == "base.en")
        #expect(installed("base.en", in: base))
    }

    @Test func installsAZip() throws {
        let work = try scratch()
        defer { try? files.removeItem(at: work) }
        let source = try makeDownloaded("tiny.en", in: work.appending(path: "other-mac"))
        let zip = work.appending(path: "SpeechModels.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try process.run()
        process.waitUntilExit()
        let base = work.appending(path: "base", directoryHint: .isDirectory)
        #expect(try SpeechModelImport.install(from: zip, into: base, variants: variants, preferred: nil) == "tiny.en")
        #expect(installed("tiny.en", in: base))
    }

    @Test func aBadImportLeavesTheInstalledModelAlone() throws {
        let work = try scratch()
        defer { try? files.removeItem(at: work) }
        let base = try makeDownloaded("base.en", in: work.appending(path: "this-mac"))
        let damaged = try makeDownloaded("base.en", in: work.appending(path: "other-mac"), tokenizer: "garbage")
        #expect(throws: SpeechModelImportError.badTokenizer) {
            try SpeechModelImport.install(from: damaged, into: base, variants: variants, preferred: nil)
        }
        #expect(installed("base.en", in: base))
        let tokenizer = try Data(contentsOf: base.appending(path: SpeechModelImport.destination(for: "base.en").tokenizer + "/tokenizer.json"))
        #expect(SpeechModelImport.isTokenizer(tokenizer))
    }

    @Test func importingTheInstalledFolderItselfCopiesNothing() throws {
        let work = try scratch()
        defer { try? files.removeItem(at: work) }
        let base = try makeDownloaded("small.en", in: work)
        #expect(try SpeechModelImport.install(from: base, into: base, variants: variants, preferred: nil) == "small.en")
        #expect(installed("small.en", in: base))
    }

    @Test func aBrokenZipSaysSo() throws {
        let work = try scratch()
        defer { try? files.removeItem(at: work) }
        let zip = work.appending(path: "model.zip")
        try Data("not a zip".utf8).write(to: zip)
        #expect(throws: (any Error).self) {
            try SpeechModelImport.install(from: zip, into: work.appending(path: "base"), variants: variants, preferred: nil)
        }
    }
}
