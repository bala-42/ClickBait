import AppKit
import ClickBaitCore
import EventKit
import Observation
import SwiftUI

/// What the gallery's pages reach in the rest of the app (set by the app delegate).
@MainActor
enum GalleryHooks {
    struct Job: Identifiable { let id: UUID; let title: String; let status: String; let tone: CompanionTone }
    static var jobs: () -> [Job] = { [] }
    static var openJob: (UUID) -> Void = { _ in }
    /// Snipping is hold-to-draw (⌥⌘): the tile says how.
    static var snip: () -> Void = {}
    static var screenshot: (ScreenshotKind) -> Void = { _ in }
    /// Opens Lookup with these words in its field.
    static var lookup: (String) -> Void = { _ in }
}

// MARK: Jobs

/// The dock's jobs: background answers, snips, walkthroughs and file jobs, with how each is
/// going; a click opens its card in the dock.
struct JobsPage: View {
    @State private var jobs = GalleryHooks.jobs()

    var body: some View {
        Group {
            if jobs.isEmpty {
                EmptyPage(symbol: "tray", text: "Nothing in the dock. Send an answer there with ⌃⌥, or a file job.")
            } else {
                VStack(spacing: 4) {
                    ForEach(jobs) { job in
                        Button { GalleryHooks.openJob(job.id) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(job.tone.color).frame(width: 7, height: 7)
                                Text(job.title).lineLimit(1).truncationMode(.tail)
                                Spacer()
                                Text(job.status).foregroundStyle(NotchPalette.tertiary)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .foregroundStyle(NotchPalette.text)
        .task { while !Task.isCancelled { jobs = GalleryHooks.jobs(); try? await Task.sleep(for: .seconds(1)) } }
    }
}

// MARK: Notes

/// ClickBait's notes and saved answers, newest first; a click opens the file.
struct NotesPage: View {
    private struct Note: Identifiable { let id: URL; let title: String; let line: String; let modified: Date }
    @State private var notes: [Note] = []

    var body: some View {
        Group {
            if notes.isEmpty {
                EmptyPage(symbol: "note.text", text: "No notes yet. Say “make a note …” to ClickBait.")
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(notes) { note in
                        Button { NSWorkspace.shared.open(note.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(note.line).font(.system(size: 11)).foregroundStyle(NotchPalette.secondary).lineLimit(2)
                                Text(note.modified.formatted(.relative(presentation: .named))).font(.system(size: 10)).foregroundStyle(NotchPalette.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .foregroundStyle(NotchPalette.text)
        .task { notes = Self.read() }
    }

    private static func read() -> [Note] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "ClickBait")
        return ["Notes", "answers"].flatMap { folder -> [Note] in
            let files = (try? FileManager.default.contentsOfDirectory(at: base.appending(path: folder), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return files.filter { $0.pathExtension == "md" }.compactMap { url in
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let line = text.split(separator: "\n").first { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return Note(id: url, title: url.deletingPathExtension().lastPathComponent, line: line, modified: modified)
            }
        }
        .sorted { $0.modified > $1.modified }.prefix(6).map { $0 }
    }
}

// MARK: Reminders

/// Open reminders, overdue and due today first; ticking one completes it in Reminders.
struct RemindersPage: View {
    private struct Item: Identifiable { let id: String; let title: String; let due: Date? }
    @State private var items: [Item] = []
    @State private var allowed = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    @State private var store = EKEventStore()

    var body: some View {
        Group {
            if !allowed {
                EmptyPage(symbol: "checklist", text: "ClickBait can't see your reminders yet: allow it in System Settings → Privacy & Security → Reminders.")
            } else if items.isEmpty {
                EmptyPage(symbol: "checkmark.circle", text: "Nothing to do. Say “remind me to …”.")
            } else {
                VStack(spacing: 4) {
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            Button { complete(item) } label: { Image(systemName: "circle").font(.system(size: 13)) }
                                .buttonStyle(.plain).accessibilityLabel("Done: \(item.title)")
                            Text(item.title).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            if let due = item.due {
                                Text(due.formatted(.relative(presentation: .named)))
                                    .font(.system(size: 11))
                                    .foregroundStyle(due < Date() ? CompanionTone.problem : NotchPalette.tertiary)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                    }
                }
            }
        }
        .foregroundStyle(NotchPalette.text)
        .task { await load() }
    }

    private func load() async {
        guard allowed else { return }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let found: [Item] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap { reminder in
                    guard let title = reminder.title, !title.isEmpty else { return nil }
                    return Item(id: reminder.calendarItemIdentifier, title: title, due: reminder.dueDateComponents?.date)
                })
            }
        }
        // Overdue and today first (by due date), then the rest.
        items = found.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(6).map { $0 }
    }

    private func complete(_ item: Item) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        withAnimation { items.removeAll { $0.id == item.id } }
    }
}

// MARK: Recent snips

/// The newest screenshots on this Mac (Spotlight's screen captures), as thumbnails: a click opens
/// one, dragging it out drops the file anywhere.
struct SnipsPage: View {
    @State private var shots: [URL] = []

    var body: some View {
        Group {
            if shots.isEmpty {
                EmptyPage(symbol: "camera.viewfinder", text: "No screenshots this week. Try the Tools tile, or ⌘⇧4.")
            } else {
                HStack(spacing: 8) {
                    ForEach(shots, id: \.self) { shot in
                        Button { NSWorkspace.shared.open(shot) } label: {
                            FileThumbnail(url: shot)
                                .frame(width: 104, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .onDrag { NSItemProvider(contentsOf: shot) ?? NSItemProvider() }
                        .help(shot.lastPathComponent)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .task { shots = await Self.recent() }
    }

    private static func recent() async -> [URL] {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["kMDItemIsScreenCapture == 1 && kMDItemContentCreationDate >= $time.today(-7)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let files = String(decoding: data, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) }
            return dated.sorted { $0.1 > $1.1 }.prefix(5).map(\.0)
        }.value
    }
}

// MARK: Tools

/// One tap each: a screenshot of an area, a window or the screen, smart search; and how to snip.
struct ToolsPage: View {
    var body: some View {
        HStack(spacing: 8) {
            tool("Area", "rectangle.dashed") { GalleryHooks.screenshot(.area) }
            tool("Window", "macwindow") { GalleryHooks.screenshot(.window) }
            tool("Screen", "display") { GalleryHooks.screenshot(.full) }
            tool("Find", "magnifyingglass") { GalleryHooks.lookup("find ") }
            tool("Snip", "lasso") { GalleryHooks.snip() }
        }
    }

    private func tool(_ name: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(name).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(NotchPalette.text)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(name)
    }
}

// MARK: Clipboard

/// What was copied this session, newest first (text and pictures), in memory only: never what
/// apps mark as secret (password managers' concealed or transient copies).
@MainActor @Observable
final class ClipboardHistory {
    static let shared = ClipboardHistory()
    struct Entry: Identifiable { let id = UUID(); let text: String?; let image: NSImage?; let at: Date }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var changeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var timer: Timer?
    private static let secret: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                              "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]

    private init() {}

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// Copies an entry back (and it becomes the newest).
    func copy(_ entry: Entry) {
        let board = NSPasteboard.general
        board.clearContents()
        if let image = entry.image { board.writeObjects([image]) } else if let text = entry.text { board.setString(text, forType: .string) }
    }

    func clear() { entries = [] }

    private func check() {
        let board = NSPasteboard.general
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount
        let types = Set((board.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.secret) else { return }
        var entry: Entry?
        if let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entry = Entry(text: String(text.prefix(2000)), image: nil, at: Date())
        } else if let image = NSImage(pasteboard: board) {
            entry = Entry(text: nil, image: image, at: Date())
        }
        guard let entry else { return }
        entries.removeAll { $0.text != nil && $0.text == entry.text }
        entries.insert(entry, at: 0)
        if entries.count > 20 { entries.removeLast(entries.count - 20) }
    }
}

struct ClipboardPage: View {
    @Bindable var history = ClipboardHistory.shared
    @State private var copied: UUID?

    var body: some View {
        Group {
            if history.entries.isEmpty {
                EmptyPage(symbol: "doc.on.clipboard", text: "What you copy shows up here, for this session only.")
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(history.entries.prefix(5)) { entry in
                        Button {
                            history.copy(entry)
                            copied = entry.id
                        } label: {
                            HStack(spacing: 8) {
                                if let image = entry.image {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 22)
                                    Text("picture").foregroundStyle(NotchPalette.secondary)
                                } else {
                                    Text(entry.text?.replacingOccurrences(of: "\n", with: " ") ?? "").lineLimit(1).truncationMode(.tail)
                                }
                                Spacer()
                                Text(copied == entry.id ? "copied ✓" : entry.at.formatted(.relative(presentation: .named)))
                                    .foregroundStyle(NotchPalette.tertiary)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Clear") { history.clear() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                }
            }
        }
        .foregroundStyle(NotchPalette.text)
    }
}

private struct EmptyPage: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(NotchPalette.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(NotchPalette.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }
}
