import ClickBaitCore
import Foundation
import Observation
import OSLog

/// Claude Code and Codex speaking up (user's ask, 2026-11-02): Claude Code's hooks append lines
/// to ClickBait's events file; Codex's session logs are read for finished turns (its `notify`
/// setting belongs to another app). Only what's new since ClickBait started counts.
@MainActor
final class AgentWatcher {
    var onNotice: ((AgentNotice) -> Void)?

    static let eventsFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "ClickBait/agent-events.jsonl")
    private static let codexSessions = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")

    private var eventsOffset: UInt64 = 0
    private var codexOffsets: [URL: UInt64] = [:]
    private var codexFolders: [URL: String] = [:]
    private var timer: Timer?

    /// Every second: cheap (two file sizes and a folder listing for today's Codex sessions).
    func start() {
        stop()  // never two timers
        Log.app.notice("Agent watcher started")
        eventsOffset = Self.size(of: Self.eventsFile)
        for file in Self.recentCodexLogs() { codexOffsets[file] = Self.size(of: file) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        for line in Self.newLines(in: Self.eventsFile, from: &eventsOffset) {
            if let notice = AgentNotice.fromHookLine(line) { onNotice?(notice) }
            AgentLiveStore.shared.see(line)
        }
        // The events file stays small: emptied once read past 256 KB.
        if eventsOffset > 262_144 { try? Data().write(to: Self.eventsFile); eventsOffset = 0 }
        for file in Self.recentCodexLogs() {
            var offset = codexOffsets[file] ?? 0  // a session started since: read from its start
            var cwd = codexFolders[file]
            for line in Self.newLines(in: file, from: &offset) {
                if let notice = AgentNotice.fromCodexLine(line, cwd: &cwd) { onNotice?(notice) }
                AgentLiveStore.shared.seeCodex(line, session: file.lastPathComponent, cwd: cwd)
            }
            codexOffsets[file] = offset
            codexFolders[file] = cwd
        }
    }

    /// Today's and yesterday's Codex sessions (a turn can cross midnight).
    private static func recentCodexLogs() -> [URL] {
        let calendar = Calendar.current
        return [Date(), Date().addingTimeInterval(-86_400)].flatMap { day -> [URL] in
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = codexSessions.appending(path: String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
    }

    private static func size(of file: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Whole lines written since `offset`, which moves past them (a half-written last line waits).
    private static func newLines(in file: URL, from offset: inout UInt64) -> [String] {
        let end = size(of: file)
        if end < offset { offset = 0 }  // emptied or replaced
        guard end > offset, let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(min(end - offset, 4_000_000))),
              let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        offset += UInt64(lastNewline - data.startIndex + 1)
        return String(decoding: data[..<lastNewline], as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

/// ClickBait's two hooks in Claude Code's settings, added after the user said yes and taken out
/// when switched off or on uninstall (`AgentHooks` does the merging). The settings file is
/// backed up once before ClickBait first writes to it.
enum AgentHookInstaller {
    static let settingsFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")

    static var command: String? {
        Bundle.main.url(forResource: "clickbait-agent-event", withExtension: "sh").map { "/bin/sh '\($0.path)' claude" }
    }

    static var isInstalled: Bool { AgentHooks.isInstalled(in: read() ?? [:]) }

    @discardableResult
    static func install() -> Bool {
        guard let command, var settings = read() ?? (FileManager.default.fileExists(atPath: settingsFile.path) ? nil : [:]) else { return false }
        backUpOnce()
        settings = AgentHooks.adding(command: command, to: settings)
        return write(settings)
    }

    @discardableResult
    static func remove() -> Bool {
        guard let settings = read(), AgentHooks.isInstalled(in: settings) || hasAny(settings) else { return true }
        return write(AgentHooks.removing(from: settings))
    }

    private static func hasAny(_ settings: [String: Any]) -> Bool {
        (try? JSONSerialization.data(withJSONObject: settings)).map { String(decoding: $0, as: UTF8.self).contains(AgentHooks.marker) } ?? false
    }

    /// Nil when there's a file that isn't readable JSON: then it's never written over.
    private static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsFile) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func write(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        do {
            try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: settingsFile, options: .atomic)
            Log.app.notice("Claude Code hooks \(AgentHooks.isInstalled(in: settings) ? "added" : "removed", privacy: .public)")
            return true
        } catch {
            Log.app.error("Couldn't update Claude Code's settings: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func backUpOnce() {
        let backup = settingsFile.appendingPathExtension("before-clickbait")
        guard FileManager.default.fileExists(atPath: settingsFile.path), !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: settingsFile, to: backup)
    }
}

/// Claude Code and Codex live, for the AI Agents page (`AgentLive` in Core). Memory only.
@MainActor @Observable
final class AgentLiveStore {
    static let shared = AgentLiveStore()
    private(set) var live = AgentLive()
    private init() {}

    func see(_ line: String) { live.see(line) }
    func seeCodex(_ line: String, session: String, cwd: String?) { live.seeCodex(line, session: session, cwd: cwd) }

    /// Sessions busy in the last two hours, the working ones first.
    var recent: [AgentLive.Session] { live.ordered.filter { $0.lastActive > Date().addingTimeInterval(-7200) } }
}
