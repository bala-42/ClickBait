import ClickBaitCore
import Foundation
import Observation
import OSLog

/// The AI Agents page's data (user's ask, 2026-11-02, after Vorssaint's): Claude Code and Codex
/// usage from their session logs on this Mac, Claude's account-wide limits from Claude Code itself
/// (the same as /usage; the Claude app's saved record when it can't answer), Codex's plan and
/// banked resets from its own local server. Read while the page shows; nothing is sent anywhere
/// by ClickBait, and only counters are kept (in memory).
@MainActor @Observable
final class AgentUsageService {
    static let shared = AgentUsageService()

    private(set) var records: [AgentUsageRecord] = []
    private(set) var claudeLimits: AgentLimits?
    private(set) var codexLimits: AgentLimits?
    /// Codex's banked resets: how many, and when the soonest expires (nil: none, or none known).
    private(set) var codexResets: (count: Int, nextExpiry: Date?)?
    private(set) var loading = false
    let prices: AgentPrices = AgentPrices(json: Bundle.main.url(forResource: "agent-prices", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) } ?? Data())

    @ObservationIgnored private var limitsReadAt: Date?
    @ObservationIgnored private let reader = AgentLogReader()

    private init() {}

    /// The newest use of each tool ("Now": working, or how long ago).
    func lastUse(of tool: AgentNotice.Tool) -> Date? {
        records.last { $0.tool == tool }?.date
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        let reader = reader
        let askLimits = limitsReadAt.map { Date().timeIntervalSince($0) > 120 } ?? true
        Task.detached(priority: .utility) {
            let (records, codexFromLogs) = reader.read()
            let claude = askLimits ? (AgentProbes.claudeUsage() ?? AgentProbes.claudeAppHistory()) : nil
            let codexAccount = askLimits ? AgentProbes.codexAccount() : nil
            await MainActor.run {
                let service = AgentUsageService.shared
                service.records = records
                if let codexFromLogs { service.codexLimits = codexFromLogs }
                if askLimits {
                    service.limitsReadAt = Date()
                    if let claude { service.claudeLimits = claude }
                    if let codexAccount {
                        if service.codexLimits?.plan == nil || service.codexLimits == nil {
                            service.codexLimits = AgentLimits(plan: codexAccount.plan, session: service.codexLimits?.session,
                                                              week: service.codexLimits?.week)
                        }
                        service.codexResets = codexAccount.resets
                    }
                }
                service.loading = false
            }
        }
    }
}

/// Reads the logs once fully, then only what each file gained since. The counters and where
/// reading stopped are kept in ClickBait's folder (`agent-usage.json`: no prompts or replies),
/// so a relaunch reads only what's new: the first full read of the user's logs (835 MB) took 23 s.
final class AgentLogReader: @unchecked Sendable {
    private let lock = NSLock()
    private var claude: [String: AgentUsageRecord] = [:]
    private var codex: [AgentUsageRecord] = []
    private var offsets: [URL: UInt64] = [:]
    private var codexState: [URL: (model: String?, cwd: String?, total: Int)] = [:]
    private var codexLimits: CodexLimits?
    private var loaded = false

    static let cacheFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "ClickBait/agent-usage.json")

    private struct Saved: Codable {
        struct CodexFile: Codable { let path: String; let model: String?; let cwd: String?; let total: Int }
        let version: Int
        let offsets: [String: UInt64]
        let claude: [String: AgentUsageRecord]
        let codex: [AgentUsageRecord]
        let codexFiles: [CodexFile]
    }

    private func load() {
        loaded = true
        guard let data = try? Data(contentsOf: Self.cacheFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == 1 else { return }
        offsets = Dictionary(uniqueKeysWithValues: saved.offsets.map { (URL(fileURLWithPath: $0.key), $0.value) })
        claude = saved.claude
        codex = saved.codex
        codexState = Dictionary(uniqueKeysWithValues: saved.codexFiles.map { (URL(fileURLWithPath: $0.path), ($0.model, $0.cwd, $0.total)) })
    }

    private func save() {
        let saved = Saved(version: 1, offsets: Dictionary(uniqueKeysWithValues: offsets.map { ($0.key.path, $0.value) }),
                          claude: claude, codex: codex,
                          codexFiles: codexState.map { Saved.CodexFile(path: $0.key.path, model: $0.value.model, cwd: $0.value.cwd, total: $0.value.total) })
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.cacheFile, options: .atomic)
    }
    /// Thirteen weeks back, as the Activity card shows.
    private static let window: TimeInterval = 91 * 86_400

    func read() -> ([AgentUsageRecord], AgentLimits?) {
        lock.lock()
        defer { lock.unlock() }
        if !loaded { load() }
        let before = offsets
        let home = FileManager.default.homeDirectoryForCurrentUser
        let since = Date().addingTimeInterval(-Self.window)
        for file in Self.files(under: home.appending(path: ".claude/projects"), since: since) {
            Self.newLines(in: file, offsets: &offsets) { line in
                if let (key, record) = AgentUsageRecord.fromClaudeLine(line) { claude[key] = record }
            }
        }
        for file in Self.files(under: home.appending(path: ".codex/sessions"), since: since) {
            var state = codexState[file] ?? (nil, nil, 0)
            Self.newLines(in: file, offsets: &offsets) { line in
                if let record = AgentUsageRecord.fromCodexLine(line, model: &state.model, cwd: &state.cwd, lastTotal: &state.total,
                                                               limits: &codexLimits) {
                    codex.append(record)
                }
            }
            codexState[file] = state
        }
        // Older than the window: dropped, so the saved file stays small.
        claude = claude.filter { $0.value.date >= since }
        codex = codex.filter { $0.date >= since }
        if offsets != before { save() }
        let all = (Array(claude.values) + codex).sorted { $0.date < $1.date }
        return (all, codexLimits?.limits)
    }

    private static func files(under root: URL, since: Date) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { url in
            url.pathExtension == "jsonl"
                && ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) >= since
        }
    }

    /// Whole lines added since the last read, in 4 MB chunks (logs reach hundreds of MB).
    private static func newLines(in file: URL, offsets: inout [URL: UInt64], each: (String) -> Void) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        var offset = offsets[file] ?? 0
        if size < offset { offset = 0 }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        var carry = Data()
        while offset + UInt64(carry.count) < size, let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            var data = carry + chunk
            guard let lastNewline = data.lastIndex(of: 0x0A) else { carry = data; continue }
            let complete = data[..<lastNewline]
            offset += UInt64(complete.count + 1)
            carry = Data(data[data.index(after: lastNewline)...])
            data = Data()
            for line in complete.split(separator: 0x0A) { each(String(decoding: line, as: UTF8.self)) }
        }
        offsets[file] = offset
    }
}

/// Asking the tools themselves, through their own channels: Claude Code's control protocol
/// (initialize, get_usage; no tools, MCP servers, hooks or saved session, no prompt) and Codex's
/// local app server (initialize, account/read). Each with a deadline.
enum AgentProbes {
    static func claudeUsage() -> AgentLimits? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let claude = candidates.first(where: FileManager.default.isExecutableFile) else { return nil }
        let arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                         "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}"]
        guard let channel = LineChannel(claude, arguments) else { return nil }
        defer { channel.close() }
        func ask(_ id: String, _ request: [String: Any]) -> [String: Any]? {
            channel.send(["type": "control_request", "request_id": id, "request": request])
            return channel.wait { message in
                guard message["type"] as? String == "control_response", let response = message["response"] as? [String: Any],
                      response["request_id"] as? String == id else { return nil }
                return response
            }
        }
        guard ask("initialize", ["subtype": "initialize"])?["subtype"] as? String == "success",
              let usage = ask("usage", ["subtype": "get_usage", "skip_behaviors": true]),
              let response = usage["response"] as? [String: Any] else { return nil }
        return AgentLimits.claude(usage: response)
    }

    static func claudeAppHistory() -> AgentLimits? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Claude/plan-usage-history.json")
        return (try? Data(contentsOf: file)).flatMap(AgentLimits.claudeApp(history:))
    }

    /// The plan, and banked resets when the plan has them. The account's email is never kept.
    static func codexAccount() -> (plan: String?, resets: (count: Int, nextExpiry: Date?)?)? {
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", "/Applications/Codex.app/Contents/Resources/codex",
                          "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let codex = candidates.first(where: FileManager.default.isExecutableFile),
              let channel = LineChannel(codex, ["-c", "features.plugins=false", "app-server"]) else { return nil }
        defer { channel.close() }
        func ask(_ id: Int, _ method: String, _ params: Any) -> [String: Any]? {
            channel.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            return channel.wait { ($0["id"] as? Int) == id ? $0 : nil }?["result"] as? [String: Any]
        }
        guard ask(1, "initialize", ["clientInfo": ["name": "ClickBait", "version": "1"], "capabilities": NSNull()]) != nil,
              let result = ask(2, "account/read", [String: Any]()) else { return nil }
        let plan = ((result["account"] as? [String: Any])?["planType"] as? String).map(AgentLimits.planName)
        var resets: (Int, Date?)?
        if let credits = result["rateLimitResetCredits"] as? [String: Any] {
            let list = credits["credits"] as? [[String: Any]] ?? []
            let expiries = list.compactMap { entry -> Date? in
                if let number = entry["expiresAt"] as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
                return (entry["expiresAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            }
            resets = (max(list.count, (credits["availableCount"] as? NSNumber)?.intValue ?? 0), expiries.min())
        }
        return (plan, resets)
    }
}

/// A tool spoken to in JSON lines over its standard input and output, with one deadline for
/// the whole conversation.
private final class LineChannel {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()
    private let deadline = Date().addingTimeInterval(12)

    init?(_ executable: String, _ arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
    }

    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
    }

    /// The first message `match` accepts, or nil at the deadline.
    func wait(_ match: ([String: Any]) -> [String: Any]?) -> [String: Any]? {
        let handle = output.fileHandleForReading
        while Date() < deadline {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let found = match(message) { return found }
            }
            var ready = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 250) >= 0 else { return nil }
            if ready.revents & Int16(POLLIN) != 0 {
                let chunk = handle.availableData
                if chunk.isEmpty { return nil }  // it ended
                buffer.append(chunk)
            }
        }
        return nil
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
