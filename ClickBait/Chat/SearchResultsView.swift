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
    /// The picture whose description is being edited, right here in the card.
    @State private var editing: SmartSearch.Item?
    /// Descriptions saved in this card, shown at once.
    @State private var edited: [String: String] = [:]

    private var pictures: [SmartSearch.Item] { items.filter { $0.kind.isVisual } }
    private var others: [SmartSearch.Item] { items.filter { !$0.kind.isVisual } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reason = items.first?.reason {
                Text(reason).font(.system(size: 11, weight: .medium)).foregroundStyle(AquaDark.textSecondary)
            }
            if !pictures.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)], alignment: .leading, spacing: 12) {
                    ForEach(pictures) { picture in
                        PictureTile(item: picture) { editing = withEdit(picture) }
                    }
                }
            }
            if let item = editing {
                DescriptionEditor(item: item) { saved in
                    if let saved { edited[item.id] = saved }
                    editing = nil
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
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

/// Right-click on a picture: correct what Vision Memory says it shows, or forget it.
private struct PictureMenu: ViewModifier {
    let item: SmartSearch.Item
    let edit: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            if item.kind.isVisual {
                Button("Edit description") { edit() }
                Button("Forget this picture") { SearchResultActions.forget(item) }
            }
        }
    }
}

extension SearchResultsView {
    /// The item with any description saved in this card.
    private func withEdit(_ item: SmartSearch.Item) -> SmartSearch.Item {
        var copy = item
        if let text = edited[item.id] { copy.caption = text.isEmpty ? nil : text }
        return copy
    }
}

/// Whether the results sit in the notch's Ask tab (solid dark) or the chat overlay (glass).
private struct ResultsInNotchKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var resultsInNotch: Bool {
        get { self[ResultsInNotchKey.self] }
        set { self[ResultsInNotchKey.self] = newValue }
    }
}

/// Correcting what a picture shows, inside the results card: the picture, its description in
/// a field of several lines (the chat's own field look, in the notch or on glass), and
/// Cancel, Describe again and Save. Your words are kept over ClickBait's.
struct DescriptionEditor: View {
    let item: SmartSearch.Item
    let done: (String?) -> Void
    @State private var text: String
    @FocusState private var focused: Bool
    @State private var anchor: NSView?
    @Environment(\.resultsInNotch) private var inNotch

    init(item: SmartSearch.Item, done: @escaping (String?) -> Void) {
        self.item = item
        self.done = done
        _text = State(initialValue: item.caption ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Thumbnail(item: item, size: CGSize(width: 64, height: 64))
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("What does this picture show?").font(.system(size: 13, weight: .semibold)).foregroundStyle(AquaDark.textPrimary)
                    Text(item.title).font(.system(size: 11)).foregroundStyle(AquaDark.textSecondary).lineLimit(1)
                    Text("Your words are kept over ClickBait's.").font(.system(size: 11)).foregroundStyle(AquaDark.textTertiary)
                }
            }
            TextField("", text: $text, prompt: Text("Describe it in your own words").foregroundStyle(AquaDark.textTertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(AquaDark.textPrimary)
                .lineLimit(3...8)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background {
                    let field = RoundedRectangle(cornerRadius: 14, style: .continuous)
                    if inNotch {
                        field.fill(NotchPalette.ink).overlay(field.stroke(Color.white.opacity(0.08), lineWidth: 1))
                    } else {
                        AquaWell(shape: field)
                    }
                }
            HStack(spacing: 8) {
                Button("Describe again") { save("") }
                    .buttonStyle(ResultPillStyle())
                    .help("Let ClickBait describe it again")
                Spacer()
                Button("Cancel") { done(nil) }
                    .buttonStyle(ResultPillStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(text) }
                    .buttonStyle(SaveStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        .background(ViewGrabber(view: $anchor))
        .onChange(of: anchor) { _, view in
            // Its window (the chat card, or the notch, which doesn't take focus by itself)
            // takes the keyboard, so the field can be typed in at once.
            view?.window?.makeKey()
            focused = true
        }
    }

    private func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await SearchIndex.shared.setCaption(item.id, trimmed) }
        done(trimmed)
    }
}

/// Save: the chat's send blue, dark text, like the notch's send button.
private struct SaveStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(enabled ? Color.black : AquaDark.textTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Capsule().fill(enabled ? AquaDark.link.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(0.08)))
            .contentShape(Capsule())
    }
}

extension Notification.Name {
    /// A result was forgotten (its id): the chat drops it from the card.
    static let clickBaitForgetResult = Notification.Name("clickBaitForgetResult")
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

    static func forget(_ item: SmartSearch.Item) {
        Task { await SearchIndex.shared.forget(item.id) }
        NotificationCenter.default.post(name: .clickBaitForgetResult, object: item.id)
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
    let edit: () -> Void
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
        .modifier(PictureMenu(item: item, edit: edit))
        .help(item.caption ?? item.file ?? item.title)
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
                Image(nsImage: image).resizable().aspectRatio(contentMode: item.kind.isVisual ? .fill : .fit)
            } else {
                Image(systemName: item.kind == .video ? "film" : item.kind == .image ? "photo" : "doc").foregroundStyle(AquaDark.textSecondary)
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
