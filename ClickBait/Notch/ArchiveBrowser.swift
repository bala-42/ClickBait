import AppKit
import ClickBaitCore
import OSLog
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Peek inside, after MacPacker's (user's ask, 2026-11-02): an archive browsed like a folder
/// without extracting a byte. Breadcrumbs, sortable Name / Size / Modified, search, Finder's
/// keys (↩ or double-click opens a folder or an archive inside, ⌘↑ goes up, space is Quick
/// Look, ⌘F searches, Esc closes). Archives inside archives open in place, streamed through
/// tar with nothing written in between; drag out exactly the files you need (only those are
/// extracted, when dropped); "extract all" lands like MacPacker's smart extraction.
@MainActor
final class ArchiveBrowser {
    static let shared = ArchiveBrowser()
    private var panel: NSPanel?
    private var model: ArchiveBrowserModel?

    func show(_ archive: URL) {
        close()
        let model = ArchiveBrowserModel(archive: archive) { [weak self] in self?.close() }
        let size = NSSize(width: 640, height: 440)
        let panel = BrowserPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 300)
        panel.contentView = NSHostingView(rootView: ArchiveBrowserView(model: model))
        // Under the notch with a gap, never on it (user's rule, 2026-11-02).
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let notchBottom = ConfirmController.notchFrames().filter { screen.frame.intersects($0) }.map(\.minY).min() ?? screen.visibleFrame.maxY
        let top = min(notchBottom - ConfirmController.notchGap, screen.visibleFrame.maxY)
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: max(top - size.height, screen.visibleFrame.minY)))
        panel.orderFrontRegardless()
        panel.makeKey()
        (self.panel, self.model) = (panel, model)
        Task {
            await model.load()
            Log.app.notice("Archive browser: \(model.level.entries.count, privacy: .public) entries, \(model.problem == nil ? "read" : "failed", privacy: .public)")
        }
    }

    func close() {
        panel?.orderOut(nil)
        model?.cleanUp()
        (panel, model) = (nil, nil)
    }

    private final class BrowserPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

/// Where the browser is: an archive (and the archives inside it it was opened through) and a
/// folder in it.
struct ArchiveLevel {
    let file: URL
    /// Paths of archives inside archives, outermost first ("inner.zip", "deep/more.7z").
    let inner: [String]
    var entries: [ArchiveListing.Entry] = []
    var folder = ""
    var name: String { inner.last.map { String($0.split(separator: "/").last ?? "") } ?? file.lastPathComponent }
}

@MainActor @Observable
final class ArchiveBrowserModel {
    private(set) var levels: [ArchiveLevel]
    var query = ""
    private(set) var loading = true
    private(set) var problem: String?
    private(set) var note: String?
    var preview: URL?
    let close: () -> Void
    /// Everything taken out to look at or drag: removed when the browser closes.
    private let scratch = FileManager.default.temporaryDirectory.appending(path: "ClickBait-peek-\(UUID().uuidString)")

    init(archive: URL, close: @escaping () -> Void) {
        levels = [ArchiveLevel(file: archive, inner: [])]
        self.close = close
    }

    var level: ArchiveLevel { levels[levels.count - 1] }

    var items: [ArchiveTree.Item] {
        query.isEmpty ? ArchiveTree.children(of: level.folder, in: level.entries) : ArchiveTree.search(query, in: level.entries)
    }

    /// The breadcrumbs: each archive, then its folders; tapping one goes there.
    var crumbs: [(title: String, depth: Int, folder: String)] {
        levels.enumerated().flatMap { depth, level -> [(String, Int, String)] in
            var path = ""
            return [(level.name, depth, "")] + level.folder.split(separator: "/").map { part in
                path += part + "/"
                return (String(part), depth, path)
            }
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let text = try await ArchiveReader.list(level)
            levels[levels.count - 1].entries = ArchiveListing.entries(text)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// ↩ / double-click: into a folder or an archive inside; a file opens in Quick Look.
    func open(_ item: ArchiveTree.Item) {
        query = ""
        if item.isFolder {
            levels[levels.count - 1].folder = item.path
        } else if item.isArchive {
            levels.append(ArchiveLevel(file: level.file, inner: level.inner + [item.path]))
            Task { await load() }
        } else {
            look(at: item)
        }
    }

    func go(depth: Int, folder: String) {
        query = ""
        levels.removeLast(levels.count - 1 - depth)
        levels[depth].folder = folder
    }

    /// ⌘↑: the parent folder, or out of an archive inside to the one holding it.
    func up() {
        query = ""
        if !level.folder.isEmpty {
            let parts = level.folder.split(separator: "/").dropLast()
            levels[levels.count - 1].folder = parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
        } else if levels.count > 1 {
            levels.removeLast()
        }
    }

    /// Space: Quick Look on a file, taken out to the scratch folder (only that file).
    func look(at item: ArchiveTree.Item) {
        guard !item.isFolder else { return }
        Task {
            do {
                preview = try await takeOut(item)
                NSApp.activate()  // Quick Look's panel shows for the active app
            } catch {
                note = "couldn't open \(item.name)"
            }
        }
    }

    /// One item out of the archive into a fresh scratch folder: a file, or a folder and all in it.
    func takeOut(_ item: ArchiveTree.Item) async throws -> URL {
        let folder = scratch.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await ArchiveReader.extract(item, from: level, into: folder)
    }

    /// For a drag: the item comes out only when it's dropped.
    func provider(for item: ArchiveTree.Item) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let type = item.isFolder ? UTType.folder : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [weak self] done in
            Task { @MainActor in
                guard let self else { return done(nil, false, CocoaError(.fileNoSuchFile)) }
                do { done(try await self.takeOut(item), false, nil) } catch { done(nil, false, error) }
            }
            return nil
        }
        return provider
    }

    /// The selection, or everything here, beside the archive: one item as itself, several in a
    /// folder named after the archive (smart extraction).
    func extract(_ chosen: [ArchiveTree.Item]) {
        note = "extracting…"
        let parent = level.file.deletingLastPathComponent()
        let base = FileActions.archiveBase(level.name)
        let current = level
        Task {
            do {
                let staging = parent.appending(path: ".clickbait-extract-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                do {
                    if chosen.isEmpty {
                        try await ArchiveReader.extractAll(from: current, into: staging)
                    } else {
                        for item in chosen { _ = try await ArchiveReader.extract(item, from: current, into: staging, flat: true) }
                    }
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    throw error
                }
                let landed = try FileActions.placeExtracted(staging, beside: parent, named: base)
                note = "extracted ✓ \(landed.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([landed])
            } catch {
                note = "couldn't extract: \(error.localizedDescription)"
            }
        }
    }

    func cleanUp() {
        let scratch = scratch
        // A moment's grace: a drop still copying from it finishes first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { try? FileManager.default.removeItem(at: scratch) }
    }
}

/// tar (macOS's libarchive) over an archive, or over archives inside archives: each inner one
/// streamed out of its holder into the next tar's input, never written down. Run as programs,
/// never through a shell; names go as escaped patterns (`ArchiveTree.tarPattern`).
enum ArchiveReader {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func list(_ level: ArchiveLevel) async throws -> String {
        let out = try await run(level, final: ["-tvf", "-"], output: nil)
        return out
    }

    /// `flat`: the item lands in `folder` by its name alone (extract selected); otherwise at
    /// its path inside the archive, and the returned URL points at it.
    static func extract(_ item: ArchiveTree.Item, from level: ArchiveLevel, into folder: URL, flat: Bool = false) async throws -> URL {
        let pattern = ArchiveTree.tarPattern(item.path)
        if item.isFolder {
            _ = try await run(level, final: ["-xf", "-", "-C", folder.path, pattern], output: nil)
            let made = folder.appending(path: item.path)
            guard flat else { return made }
            let target = folder.appending(path: item.name)
            if made.standardizedFileURL != target.standardizedFileURL {
                try FileManager.default.moveItem(at: made, to: target)
                try? FileManager.default.removeItem(at: folder.appending(path: String(item.path.split(separator: "/").first ?? "")))
            }
            return target
        }
        let target = folder.appending(path: item.name)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        _ = try await run(level, final: ["-xOf", "-", pattern], output: handle)
        return target
    }

    static func extractAll(from level: ArchiveLevel, into folder: URL) async throws {
        _ = try await run(level, final: ["-xf", "-", "-C", folder.path], output: nil)
    }

    /// The chain: `tar -xOf <file> inner1 | tar -xOf - inner2 | … | tar <final>`, where the
    /// final's "-" reads the file itself when there's nothing inside to go through.
    private static func run(_ level: ArchiveLevel, final: [String], output: FileHandle?) async throws -> String {
        let file = level.file.path
        var steps = level.inner.enumerated().map { index, path in ["-xOf", index == 0 ? file : "-", ArchiveTree.tarPattern(path)] }
        steps.append(level.inner.isEmpty ? final.map { $0 == "-" ? file : $0 } : final)
        // The stand-in password right after the archive: tar reads anything after a name as
        // another name ("--passphrase: Not found in archive").
        let arguments = steps.map { Array($0.prefix(2)) + FileActions.noPassword + $0.dropFirst(2) }
        return try await Task.detached(priority: .userInitiated) {
            var processes: [Process] = []
            var previous: Pipe?
            // One error pipe each: a pipe's writing end is closed here once its program starts,
            // so a shared one couldn't be handed to the next (it crashed).
            var errors: [Pipe] = []
            let result = Pipe()
            for (index, args) in arguments.enumerated() {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = args
                process.standardInput = previous ?? FileHandle.nullDevice
                let error = Pipe()
                process.standardError = error
                errors.append(error)
                if index == arguments.count - 1 {
                    process.standardOutput = output ?? result
                } else {
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    previous = pipe
                }
                processes.append(process)
            }
            for process in processes { try process.run() }
            let text = output == nil ? result.fileHandleForReading.readDataToEndOfFile() : Data()
            for process in processes { process.waitUntilExit() }
            let problem = errors.map { String(decoding: $0.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }.joined()
            guard processes.allSatisfy({ $0.terminationStatus == 0 }) else {
                throw Failure(message: FileActions.isLocked(problem) ? "it's password-locked" : (problem.split(separator: "\n").first.map(String.init) ?? "tar couldn't read it"))
            }
            return String(decoding: text, as: UTF8.self)
        }.value
    }
}

private struct BrowserRow: Identifiable {
    let item: ArchiveTree.Item
    var id: String { item.id }
    var name: String { item.name }
    var bytes: Int64 { item.bytes }
    var modified: Date { item.modified ?? .distantPast }
}

struct ArchiveBrowserView: View {
    @Bindable var model: ArchiveBrowserModel
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\BrowserRow.name, comparator: .localizedStandard)]
    @FocusState private var searching: Bool

    private var rows: [BrowserRow] {
        let sorted = model.items.map(BrowserRow.init).sorted(using: sortOrder)
        return sorted.filter(\.item.isFolder) + sorted.filter { !$0.item.isFolder }  // folders first, as Finder
    }

    private var chosen: [ArchiveTree.Item] { rows.filter { selection.contains($0.id) }.map(\.item) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Color.white.opacity(0.08))
            ZStack {
                table
                if model.loading { ProgressView().controlSize(.small) }
                if let problem = model.problem {
                    Text("couldn't look inside: \(problem)").font(.system(size: 12)).foregroundStyle(NotchPalette.secondary)
                }
            }
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .background(Color(hex: 0x141518), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .quickLookPreview($model.preview)
        .onExitCommand { model.query.isEmpty ? model.close() : (model.query = "") }
        .onChange(of: model.level.folder) { selection = [] }
        .onChange(of: model.levels.count) { selection = [] }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.up() } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.levels.count == 1 && model.level.folder.isEmpty)
                .help("Up (⌘↑)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(NotchPalette.tertiary) }
                        Button(crumb.title) { model.go(depth: crumb.depth, folder: crumb.folder) }
                            .font(.system(size: 12, weight: index == model.crumbs.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == model.crumbs.count - 1 ? NotchPalette.text : NotchPalette.secondary)
                    }
                }
            }
            TextField("search", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 8).frame(width: 160, height: 24)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .focused($searching)
            Button { searching = true } label: { EmptyView() }.keyboardShortcut("f").hidden().frame(width: 0)
            Button { model.close() } label: { Image(systemName: "xmark") }.help("Close (Esc)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(NotchPalette.secondary)
        .padding(.horizontal, 12).frame(height: 44)
    }

    private var table: some View {
        Table(of: BrowserRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                HStack(spacing: 8) {
                    Image(nsImage: icon(for: row.item)).resizable().frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.name).lineLimit(1)
                        if !model.query.isEmpty, row.item.path.contains("/") {
                            Text(row.item.path).font(.system(size: 10)).foregroundStyle(NotchPalette.tertiary).lineLimit(1)
                        }
                    }
                }
            }
            TableColumn("Size", value: \.bytes) { row in
                Text(row.item.isFolder && row.bytes == 0 ? "—" : ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))
                    .foregroundStyle(NotchPalette.secondary).monospacedDigit()
            }
            .width(min: 64, ideal: 80, max: 120)
            TableColumn("Modified", value: \.modified) { row in
                Text(row.item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—").foregroundStyle(NotchPalette.secondary)
            }
            .width(min: 100, ideal: 150, max: 200)
        } rows: {
            ForEach(rows) { row in
                TableRow(row).itemProvider { model.provider(for: row.item) }
            }
        }
        .font(.system(size: 12))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = rows.filter { ids.contains($0.id) }.map(\.item)
            Button("Extract") { model.extract(picked) }.disabled(picked.isEmpty)
            if let one = picked.first, picked.count == 1, !one.isFolder { Button("Quick Look") { model.look(at: one) } }
        } primaryAction: { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) { model.open(row.item) }
        }
        .onKeyPress(.space) {
            guard let item = chosen.first else { return .ignored }
            model.preview == nil ? model.look(at: item) : (model.preview = nil)
            return .handled
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            let files = model.level.entries.filter { !$0.isFolder }
            Text(model.note ?? "\(files.count == 1 ? "1 file" : "\(files.count) files"), \(ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.bytes }, countStyle: .file)) · drag files out to take just those")
                .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary).lineLimit(1)
            Spacer()
            if !chosen.isEmpty {
                Button("extract \(chosen.count)") { model.extract(chosen) }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }
            Button("extract all") { model.extract([]) }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(CompanionTone.action.color, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).frame(height: 40)
    }

    private func icon(for item: ArchiveTree.Item) -> NSImage {
        if item.isFolder { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
    }
}
