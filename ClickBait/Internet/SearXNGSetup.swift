import AppKit
import ClickBaitCore
import SwiftUI

/// Optional SearXNG on this Mac (spec decision 1): its status, and plain setup steps.
@MainActor
@Observable
final class SearXNGStatus {
    enum State: Equatable { case checking, ready, notSetUp }

    private(set) var state: State = .checking
    private let fetcher: WebFetcher

    init(fetcher: WebFetcher) {
        self.fetcher = fetcher
    }

    var isReady: Bool { state == .ready }

    func check() async {
        state = await fetcher.searxngReady() ? .ready : .notSetUp
    }

    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "ClickBait/searxng", directoryHint: .isDirectory)
    }

    static let command = #"docker run -d --name clickbait-searxng --restart unless-stopped -p 127.0.0.1:8888:8080 -v "$HOME/Library/Application Support/ClickBait/searxng:/etc/searxng" searxng/searxng"#

    /// SearXNG's stock settings only serve HTML; ClickBait needs JSON results. Writes
    /// `settings.yml` with JSON on, the bot limiter off (it's only reachable from this Mac)
    /// and a random secret. Local file only.
    static func prepareSettings() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let secret = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let yaml = """
            # Written by ClickBait. SearXNG's defaults, plus JSON results for ClickBait on this Mac.
            use_default_settings: true
            server:
              secret_key: "\(secret)"
              limiter: false
              image_proxy: false
            search:
              formats:
                - html
                - json
            """
        let file = folder.appending(path: "settings.yml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

/// Settings → Internet.
struct InternetSettingsSection: View {
    let searxng: SearXNGStatus
    @State private var prepared: String?
    @State private var copied = false

    var body: some View {
        Text("Switch Internet Mode on from the menu bar (🔒 → 🌐); it's off every time ClickBait starts. Only search words and page addresses are sent — never your screen, its text, your voice or anyone's name on it — to Wikipedia, Stack Overflow, MDN and Apple's developer docs, and to SearXNG if you run it. The answers still come from the model on this Mac.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            Text("SearXNG on this Mac")
            Spacer()
            switch searxng.state {
            case .checking: ProgressView().controlSize(.small)
            case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notSetUp: Text("Not set up (optional)").foregroundStyle(.secondary)
            }
            Button("Check Again") { Task { await searxng.check() } }
        }
        .task { await searxng.check() }

        if searxng.state == .notSetUp {
            VStack(alignment: .leading, spacing: 6) {
                Text("Optional: a private search engine on your Mac widens what Internet Mode can find. Without it, lookups still work.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("1. Install Docker Desktop or OrbStack (free for personal use).\n2. Click Prepare Settings.\n3. Run the command below in Terminal, then click Check Again.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Prepare Settings") {
                        do { prepared = "Saved \(try SearXNGStatus.prepareSettings().path)" }
                        catch { prepared = "Couldn't save the settings: \(error.localizedDescription)" }
                    }
                    if let prepared { Text(prepared).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                HStack(alignment: .top) {
                    Text(SearXNGStatus.command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SearXNGStatus.command, forType: .string)
                        copied = true
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
