import Foundation

/// Sending files to the other Macs running ClickBait on the same network (user's choice,
/// 2026-11-02, "option 1": Blip's idea of sending to your own devices by name, without a
/// server). The wire format, decided here: each control message is a 4-byte big-endian length
/// and a JSON `Message`; after an accepted offer the files' bytes follow in order, each from
/// the offset the receiver asked for (a part it already has: resumed).
public enum LocalTransfer {
    public static let serviceType = "_clickbait-send._tcp"
    /// A control message bigger than this is refused (it comes from the network).
    public static let maxMessage = 1 << 20
    /// Files in one offer, at most.
    public static let maxFiles = 500

    public struct File: Codable, Equatable, Sendable {
        public let name: String
        public let size: Int64
        public init(name: String, size: Int64) { (self.name, self.size) = (name, size) }
    }

    public enum Message: Codable, Equatable, Sendable {
        case offer(from: String, files: [File])
        /// Where each file starts: 0, or the bytes already received last time.
        case accept(offsets: [Int64])
        case decline
        case done
    }

    public static func frame(_ message: Message) throws -> Data {
        let body = try JSONEncoder().encode(message)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// A frame's body length from its 4-byte prefix; nil when it's too big to trust.
    public static func length(_ prefix: Data) -> Int? {
        guard prefix.count == 4 else { return nil }
        let length = Int(prefix.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        return length <= maxMessage ? length : nil
    }

    public static func message(_ body: Data) -> Message? { try? JSONDecoder().decode(Message.self, from: body) }

    /// A file name sent by another Mac, safe to save in Downloads: no folders, no "..", not
    /// hidden, not empty, not endless.
    public static func safeName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "file" }
        return String(name.prefix(200))
    }

    /// Where a file resumes: the part already saved, if it's shorter than the file; else 0.
    public static func resumeOffset(partSize: Int64?, fileSize: Int64) -> Int64 {
        guard let partSize, partSize > 0, partSize < fileSize else { return 0 }
        return partSize
    }

    /// "3 files, 12 MB" / "1 file, 4 KB".
    public static func summary(_ files: [File]) -> String {
        let size = ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file)
        return "\(files.count == 1 ? "1 file" : "\(files.count) files"), \(size)"
    }
}
