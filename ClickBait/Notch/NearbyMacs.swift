import AppKit
import ClickBaitCore
import Network
import Observation
import OSLog

/// The other Macs running ClickBait on this network, by name, and sending them the shelf's
/// files (user's choice, 2026-11-02: Blip's idea, "option 1"). Found with Bonjour (Wi-Fi,
/// Ethernet, or Apple's peer-to-peer link between nearby Macs); files go Mac to Mac, no server.
/// The receiving Mac asks first, saves into Downloads, and resumes a transfer cut off.
/// shortcut: the bytes cross the local network unencrypted, like most LAN file tools; add TLS
/// with a pairing code if it's ever used on networks the user doesn't trust.
@MainActor @Observable
final class NearbyMacs {
    static let shared = NearbyMacs()

    struct Peer: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    enum Status: Equatable {
        case idle
        case waiting(to: String)
        case sending(to: String, progress: Double)
        case sent(to: String, count: Int)
        case failed(String)
    }

    private(set) var peers: [Peer] = []
    private(set) var status: Status = .idle
    /// Asks the user whether to take an offer ("Studio Mac wants to send 3 files, 12 MB"); set
    /// by the app delegate (a card by the cursor).
    @ObservationIgnored var ask: (_ question: String, _ answer: @escaping (Bool) -> Void) -> Void = { _, answer in answer(false) }
    /// Received files (set by the app delegate: a pill, Finder on click).
    @ObservationIgnored var onReceived: (_ from: String, _ files: [URL]) -> Void = { _, _ in }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var ownName = Host.current().localizedName ?? "Mac"
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    private init() {}

    private static var parameters: NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: Self.parameters)
            listener.service = NWListener.Service(name: ownName, type: LocalTransfer.serviceType)
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                // Bonjour may rename us ("Mac (2)"): that's the name the others see, so skip it.
                if case .add(let endpoint) = change, case .service(let name, _, _, _) = endpoint {
                    Task { @MainActor in self?.ownName = name }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in await self?.receive(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Log.app.error("Nearby: couldn't listen: \(error.localizedDescription, privacy: .public)")
        }
        let browser = NWBrowser(for: .bonjour(type: LocalTransfer.serviceType, domain: nil), using: Self.parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.found(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
        Log.app.notice("Nearby: listening as \(self.ownName, privacy: .public)")
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
        (listener, browser, peers) = (nil, nil, [])
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        peers = results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint, name != ownName else { return nil }
            return Peer(name: name, endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Sending

    func send(_ urls: [URL], to peer: Peer) {
        let files = urls.filter { !$0.hasDirectoryPath }.prefix(LocalTransfer.maxFiles)
        guard !files.isEmpty else { status = .failed("pick files, not folders"); settle(); return }
        Task { @MainActor in
            let connection = NWConnection(to: peer.endpoint, using: Self.parameters)
            defer { connection.cancel() }
            do {
                try await connection.ready()
                let sizes = try files.map { Int64(try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
                let offer = zip(files, sizes).map { LocalTransfer.File(name: $0.lastPathComponent, size: $1) }
                status = .waiting(to: peer.name)
                try await connection.send(message: .offer(from: ownName, files: offer))
                guard case .accept(let offsets) = try await connection.message(), offsets.count == offer.count else {
                    status = .failed("\(peer.name) said no")
                    settle()
                    return
                }
                let total = Double(max(1, zip(sizes, offsets).reduce(0) { $0 + $1.0 - $1.1 }))
                var sent: Int64 = 0
                for (index, url) in files.enumerated() {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(offsets[index]))
                    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                        try await connection.send(data: chunk)
                        sent += Int64(chunk.count)
                        status = .sending(to: peer.name, progress: Double(sent) / total)
                    }
                }
                guard case .done = try await connection.message() else { throw TransferError.cutOff }
                status = .sent(to: peer.name, count: files.count)
                Log.app.notice("Nearby: sent \(files.count, privacy: .public) file(s)")
            } catch {
                status = .failed("couldn't reach \(peer.name)")
                Log.app.error("Nearby: send failed: \(error.localizedDescription, privacy: .public)")
            }
            settle()
        }
    }

    private func settle() {
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.status = .idle
        }
    }

    // MARK: Receiving

    private func receive(_ connection: NWConnection) async {
        defer { connection.cancel() }
        do {
            try await connection.ready()
            guard case .offer(let from, let files) = try await connection.message(),
                  !files.isEmpty, files.count <= LocalTransfer.maxFiles, files.allSatisfy({ $0.size >= 0 }) else { return }
            let accepted = await withCheckedContinuation { continuation in
                ask("\(LocalTransfer.safeName(from)) wants to send \(LocalTransfer.summary(files)). accept?") { continuation.resume(returning: $0) }
            }
            guard accepted else { try? await connection.send(message: .decline); return }
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let parts = files.map { downloads.appending(path: LocalTransfer.safeName($0.name) + ".clickbait-part") }
            let offsets = zip(parts, files).map { part, file in
                LocalTransfer.resumeOffset(partSize: (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init), fileSize: file.size)
            }
            try await connection.send(message: .accept(offsets: offsets))
            var saved: [URL] = []
            for (index, file) in files.enumerated() {
                let part = parts[index]
                if offsets[index] == 0 { FileManager.default.createFile(atPath: part.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: part)
                try handle.truncate(atOffset: UInt64(offsets[index]))
                try handle.seekToEnd()
                var left = file.size - offsets[index]
                while left > 0 {
                    let chunk = try await connection.receive(exactly: Int(min(left, 1 << 20)))
                    try handle.write(contentsOf: chunk)
                    left -= Int64(chunk.count)
                }
                try handle.close()
                let final = Self.unique(downloads.appending(path: LocalTransfer.safeName(file.name)))
                try FileManager.default.moveItem(at: part, to: final)
                saved.append(final)
            }
            try await connection.send(message: .done)
            Log.app.notice("Nearby: received \(saved.count, privacy: .public) file(s)")
            onReceived(LocalTransfer.safeName(from), saved)
        } catch {
            // A cut-off transfer keeps its parts: the next send of the same files resumes.
            Log.app.error("Nearby: receive stopped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// "photo.jpg", or "photo 2.jpg" when that's taken.
    private static func unique(_ url: URL) -> URL {
        var candidate = url, number = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}

enum TransferError: Error { case cutOff, tooBig }

private extension NWConnection {
    func ready() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Runs on the main queue only (`start(queue: .main)`), so the flag needs no lock.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready: once.done = true; continuation.resume()
                case .failed(let error), .waiting(let error): once.done = true; continuation.resume(throwing: error)
                case .cancelled: once.done = true; continuation.resume(throwing: TransferError.cutOff)
                default: break
                }
            }
            start(queue: .main)
        }
    }

    func send(data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func send(message: LocalTransfer.Message) async throws {
        try await send(data: try LocalTransfer.frame(message))
    }

    func receive(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: TransferError.cutOff) }
            }
        }
    }

    func message() async throws -> LocalTransfer.Message {
        guard let length = LocalTransfer.length(try await receive(exactly: 4)) else { throw TransferError.tooBig }
        guard let message = LocalTransfer.message(try await receive(exactly: length)) else { throw TransferError.cutOff }
        return message
    }
}
