import AppKit
import ClickBaitCore
import Photos
import QuickLookThumbnailing
import SwiftUI

/// Smart search's results in the chat, like Taby's: why they matched, pictures as a grid of
/// big thumbnails, files with their previews, notes and reminders as rows; each with folder,
/// date and size, and Open and Show in Finder buttons. Click opens; files and pictures drag
/// out; Copy and Share on hover. "Listen again" reads the answer out once more.
struct SearchResultsView: View {
    let items: [SmartSearch.Item]
    let answer: String

    private var pictures: [SmartSearch.Item] { items.filter { $0.kind == .image } }
    private var others: [SmartSearch.Item] { items.filter { $0.kind != .image } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reason = items.first?.reason {
                Text(reason).font(.system(size: 11, weight: .medium)).foregroundStyle(AquaDark.textSecondary)
            }
            if !pictures.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)], alignment: .leading, spacing: 12) {
                    ForEach(pictures) { PictureTile(item: $0) }
                }
            }
            ForEach(others) { ResultRow(item: $0) }
            Button {
                NotificationCenter.default.post(name: .clickBaitListenAgain, object: answer)
            } label: {
                Label("Listen again", systemImage: "speaker.wave.2")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(AquaDark.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }
}

extension Notification.Name {
    /// The results card's "Listen again": the answer's text, read aloud again.
    static let clickBaitListenAgain = Notification.Name("clickBaitListenAgain")
}

/// Opening, copying and sharing one result.
@MainActor
enum SearchResultActions {
    /// "Open it", "show the second one in Finder": does it, and says what it did.
    static func perform(_ followUp: SmartSearch.FollowUp, on items: [SmartSearch.Item]) -> String {
        switch followUp {
        case .open(let index):
            let item = items[index]
            open(item)
            return "Opening \(item.title)."
        case .reveal(let index):
            let item = items[index]
            guard let path = item.file else { open(item); return "Opening \(item.title)." }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return "Here's \(item.title) in Finder."
        }
    }

    static func open(_ item: SmartSearch.Item) {
        if let path = item.file {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if item.id.hasPrefix("applenote:") {
            let id = item.id.dropFirst("applenote:".count)
            Task.detached {
                let script = "tell application \"Notes\"\nshow note id \"\(id)\"\nactivate\nend tell"
                NSAppleScript(source: script)?.executeAndReturnError(nil)
            }
        } else if item.kind == .reminder {
            openApp("com.apple.reminders")
        } else if item.id.hasPrefix("photo:") {
            openApp("com.apple.Photos")
        }
    }

    static func copy(_ item: SmartSearch.Item) {
        let board = NSPasteboard.general
        board.clearContents()
        if let path = item.file {
            board.writeObjects([URL(fileURLWithPath: path) as NSURL])
            if item.kind == .image, let image = NSImage(contentsOfFile: path) { board.writeObjects([image]) }
        } else {
            board.setString([item.title, item.text].filter { !$0.isEmpty }.joined(separator: "\n"), forType: .string)
        }
    }

    static func share(_ item: SmartSearch.Item, from view: NSView?) {
        guard let path = item.file, let view else { return }
        NSSharingServicePicker(items: [URL(fileURLWithPath: path)])
            .show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    static func dragItem(_ item: SmartSearch.Item) -> NSItemProvider {
        if let path = item.file, let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: path)) { return provider }
        return NSItemProvider(object: item.title as NSString)
    }

    private static func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// A picture: its thumbnail, name and where it is; Copy and Share on hover.
private struct PictureTile: View {
    let item: SmartSearch.Item
    @State private var hovering = false
    @State private var copied = false
    @State private var anchor: NSView?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Thumbnail(item: item, size: CGSize(width: 180, height: 136))
                .frame(height: 118)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if hovering || copied {
                        HStack(spacing: 4) {
                            ResultButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                                SearchResultActions.copy(item)
                                copied = true
                                Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                            }
                            if item.file != nil {
                                ResultButton(symbol: "square.and.arrow.up", help: "Share") { SearchResultActions.share(item, from: anchor) }
                                    .background(ViewGrabber(view: $anchor))
                            }
                        }
                        .padding(5)
                    }
                }
            Text(item.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(AquaDark.textPrimary).lineLimit(2)
            Text(item.details()).font(.system(size: 10)).foregroundStyle(AquaDark.textSecondary).lineLimit(1)
            OpenButtons(item: item)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { SearchResultActions.open(item) }
        .onDrag { SearchResultActions.dragItem(item) }
        .help(item.file ?? item.title)
    }
}

/// A file, note or reminder: preview or icon, name, where it is, a line of what it says.
private struct ResultRow: View {
    let item: SmartSearch.Item
    @State private var hovering = false
    @State private var anchor: NSView?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if item.file != nil {
                    Thumbnail(item: item, size: CGSize(width: 36, height: 44))
                } else {
                    Image(systemName: item.kind == .reminder ? "checklist" : "note.text")
                        .font(.system(size: 16))
                        .foregroundStyle(AquaDark.textSecondary)
                }
            }
            .frame(width: 36, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AquaDark.textPrimary).lineLimit(1)
                Text(item.details()).font(.system(size: 11)).foregroundStyle(AquaDark.textSecondary).lineLimit(1)
                let snippet = item.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                if !snippet.isEmpty {
                    Text(snippet).font(.system(size: 12)).foregroundStyle(AquaDark.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                OpenButtons(item: item)
                if hovering, item.file != nil {
                    HStack(spacing: 4) {
                        ResultButton(symbol: "doc.on.doc", help: "Copy") { SearchResultActions.copy(item) }
                        ResultButton(symbol: "square.and.arrow.up", help: "Share") { SearchResultActions.share(item, from: anchor) }
                            .background(ViewGrabber(view: $anchor))
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering ? 0.09 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { SearchResultActions.open(item) }
        .onDrag { SearchResultActions.dragItem(item) }
    }
}

/// "Open" and a folder button (Show in Finder), always shown, as in Taby's results.
private struct OpenButtons: View {
    let item: SmartSearch.Item

    var body: some View {
        HStack(spacing: 6) {
            Button("Open") { SearchResultActions.open(item) }
                .buttonStyle(ResultPillStyle())
            if let path = item.file {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ResultPillStyle())
                .help("Show in Finder")
            }
        }
    }
}

private struct ResultPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AquaDark.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().strokeBorder(Color.white.opacity(configuration.isPressed ? 0.5 : 0.25)))
            .contentShape(Capsule())
    }
}

private struct ResultButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A file's Quick Look preview (pictures, PDFs, documents), or a Photos thumbnail.
private struct Thumbnail: View {
    let item: SmartSearch.Item
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: item.kind == .image ? .fill : .fit)
            } else {
                Image(systemName: item.kind == .image ? "photo" : "doc").foregroundStyle(AquaDark.textSecondary)
            }
        }
        .task(id: item.id) { image = await load() }
    }

    private func load() async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if let path = item.file {
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: size, scale: scale,
                                                       representationTypes: .thumbnail)
            return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        guard item.id.hasPrefix("photo:"),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [String(item.id.dropFirst(6))], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = false
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed, !degraded || image == nil else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}

/// Hands back the NSView under a SwiftUI view, for the Share picker to hang from.
private struct ViewGrabber: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.view = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
