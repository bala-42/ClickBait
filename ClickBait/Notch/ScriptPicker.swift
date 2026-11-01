import AppKit
import SwiftUI

/// Studio's own script picker (user's ask, 2026-11-01: the file picker "should have the same
/// visual theme as the prompter notch, black and stuff"; macOS's can only be dark, not
/// restyled): inside Studio, in the notch's black — your recent scripts (text, Markdown, Word,
/// RTF, web pages, PDFs) newest first, filtered as you type, Spotlight searched for the rest;
/// "Somewhere else…" for the system picker, as a sheet on the notch.
struct ScriptPicker: View {
    @Bindable var studio: StudioModel
    let close: () -> Void
    @State private var files: [URL] = []
    @State private var query = ""
    @State private var searched: [URL]?
    @State private var loading = true
    @FocusState private var searchFocused: Bool

    static let extensions = ["txt", "md", "markdown", "rtf", "rtfd", "docx", "doc", "html", "htm", "pdf"]

    private var shown: [URL] {
        if let searched { return searched }
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return files }
        return files.filter { file in words.allSatisfy { file.lastPathComponent.lowercased().contains($0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                TextField("", text: $query, prompt: Text("Find a script").foregroundStyle(NotchPalette.tertiary))
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(NotchPalette.text)
                    .focused($searchFocused)
                    .onSubmit { search() }
                    .onChange(of: query) { _, _ in searched = nil }
                Button("Somewhere else…") { browse() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(NotchPalette.highlight)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(NotchPalette.secondary).accessibilityLabel("Close the picker")
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NotchPalette.ink))
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    if loading {
                        ProgressView().controlSize(.small).padding(.top, 30)
                    } else if shown.isEmpty {
                        Text(query.isEmpty ? "No scripts found on this Mac." : "Nothing called that. Press Return to search inside files.")
                            .font(.system(size: 11.5)).foregroundStyle(NotchPalette.secondary).padding(.top, 30)
                    }
                    ForEach(shown, id: \.self) { file in row(file) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .task {
            files = await Self.recentScripts()
            loading = false
            ShelfDrop.focusNotch()
            searchFocused = true
        }
    }

    private func row(_ file: URL) -> some View {
        Button { open(file) } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.deletingPathExtension().lastPathComponent).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(NotchPalette.text).lineLimit(1)
                    Text(Self.details(file)).font(.system(size: 10.5)).foregroundStyle(NotchPalette.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(PickerRowStyle())
    }

    private func open(_ file: URL) {
        studio.load(file)
        close()
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = StudioModel.fileTypes
        panel.message = "Choose a script: text, Markdown, Word, RTF, a web page or a PDF."
        panel.openFromNotch { urls in
            if let url = urls.first { open(url) }
        }
    }

    /// Return in the search field: Spotlight, inside the files too.
    private func search() {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return }
        loading = true
        Task {
            searched = await Self.spotlight(words)
            loading = false
        }
    }

    /// "Downloads · Oct 30"
    static func details(_ file: URL) -> String {
        let folder = file.deletingLastPathComponent().lastPathComponent
        guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return folder }
        return folder + " · " + date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The newest script-like files in the home folder (Library, Trash, code folders left out), by Spotlight.
    /// Recent ones are writing formats only: PDFs were mostly receipts, transcripts and ID
    /// scans (found here, not scripts); they still turn up by searching.
    static let writing = ["txt", "md", "markdown", "rtf", "rtfd", "docx", "doc"]

    static func recentScripts() async -> [URL] {
        let names = writing.map { "kMDItemFSName == \"*.\($0)\"c" }.joined(separator: " || ")
        return await run("(\(names)) && kMDItemFSContentChangeDate >= $time.today(-365)", limit: 60)
    }

    static func spotlight(_ text: String) async -> [URL] {
        let names = extensions.map { "kMDItemFSName == \"*.\($0)\"c" }.joined(separator: " || ")
        let safe = text.replacingOccurrences(of: "\"", with: "")
        return await run("(\(names)) && (kMDItemFSName == \"*\(safe)*\"cd || kMDItemTextContent == \"*\(safe)*\"cd)", limit: 60)
    }

    private static func run(_ query: String, limit: Int) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", FileManager.default.homeDirectoryForCurrentUser.path, query]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let skip = ["/Library/", "/.Trash/", "/node_modules/", "/.git/", "/DerivedData/", "/site-packages/", "/build/", "/.venv/", "/venv"]
            let urls = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                .filter { path in !skip.contains(where: path.contains) && !path.contains("/.") }
                // Project files, not scripts.
                .filter { path in
                    let name = (path as NSString).lastPathComponent.uppercased()
                    return !["README", "LICENSE", "CHANGELOG", "CLAUDE", "AGENTS", "CONTRIBUTING", "NOTICE", "SKILL"].contains { name.hasPrefix($0) }
                }
                .map { URL(fileURLWithPath: $0) }
            let dated = urls.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            return Array(dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0))
        }.value
    }
}

private struct PickerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0)))
            .onHover { _ in }
    }
}
