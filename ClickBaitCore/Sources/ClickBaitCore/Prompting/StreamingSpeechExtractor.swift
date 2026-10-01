/// Pulls the `"speech"` string out of a JSON reply *while it streams*, so speaking can
/// start before the pointers arrive. Feed it chunks as they come; each call returns
/// the newly decoded speech text (possibly empty). Escapes split across chunks
/// (`\"`, `\n`, `é`, surrogate pairs) are held until complete.
public struct StreamingSpeechExtractor: Sendable {
    private enum Phase: Sendable {
        case seekingKey
        case seekingColon
        case seekingOpenQuote
        case inString
        case done
    }

    private static let key = Array("\"speech\"".unicodeScalars)

    private var scalars: [Unicode.Scalar] = []
    private var position = 0
    private var phase = Phase.seekingKey
    private var pendingHighSurrogate: UInt32?

    public init() {}

    /// True once the closing quote of the speech string has been seen.
    public var isComplete: Bool {
        if case .done = phase { return true }
        return false
    }

    public mutating func feed(_ chunk: String) -> String {
        scalars.append(contentsOf: chunk.unicodeScalars)
        var output = String.UnicodeScalarView()

        loop: while position < scalars.count {
            switch phase {
            case .seekingKey:
                guard let match = findKey() else { break loop }
                position = match + Self.key.count
                phase = .seekingColon
            case .seekingColon:
                let scalar = scalars[position]
                if scalar == ":" { phase = .seekingOpenQuote }
                else if !scalar.properties.isWhitespace { phase = .seekingKey }  // was a value, not the key
                position += 1
            case .seekingOpenQuote:
                let scalar = scalars[position]
                if scalar == "\"" { phase = .inString }
                else if !scalar.properties.isWhitespace { phase = .done }  // speech isn't a string
                position += 1
            case .inString:
                let scalar = scalars[position]
                if scalar == "\"" {
                    phase = .done
                    position += 1
                } else if scalar == "\\" {
                    guard let (decoded, length) = decodeEscape(at: position) else { break loop }  // incomplete
                    if let decoded { output.append(decoded) }
                    position += length
                } else {
                    output.append(scalar)
                    position += 1
                }
            case .done:
                break loop
            }
        }
        return String(output)
    }

    /// Index of the next `"speech"` at or after `position`, or nil if it may still be
    /// arriving. Keeps `position` just before a possible partial match.
    private mutating func findKey() -> Int? {
        let key = Self.key
        var index = position
        while index + key.count <= scalars.count {
            if Array(scalars[index..<(index + key.count)]) == key { return index }
            index += 1
        }
        position = max(position, scalars.count - (key.count - 1))
        return nil
    }

    /// Returns the decoded scalar (nil when an escape produces nothing yet, e.g. a high
    /// surrogate waiting for its pair) and how many input scalars it used, or nil if
    /// the escape isn't complete yet.
    private mutating func decodeEscape(at index: Int) -> (Unicode.Scalar?, Int)? {
        guard index + 1 < scalars.count else { return nil }
        let simple: [Unicode.Scalar: Unicode.Scalar] = [
            "\"": "\"", "\\": "\\", "/": "/", "b": "\u{08}", "f": "\u{0C}", "n": "\n", "r": "\r", "t": "\t",
        ]
        let kind = scalars[index + 1]
        if let mapped = simple[kind] { return (mapped, 2) }
        guard kind == "u" else { return (nil, 2) }  // invalid escape: skip it
        guard index + 6 <= scalars.count else { return nil }
        let hex = String(String.UnicodeScalarView(scalars[(index + 2)..<(index + 6)]))
        guard let value = UInt32(hex, radix: 16) else { return (nil, 6) }

        if (0xD800...0xDBFF).contains(value) {
            pendingHighSurrogate = value
            return (nil, 6)
        }
        if (0xDC00...0xDFFF).contains(value), let high = pendingHighSurrogate {
            pendingHighSurrogate = nil
            let combined = 0x10000 + ((high - 0xD800) << 10) + (value - 0xDC00)
            return (Unicode.Scalar(combined), 6)
        }
        pendingHighSurrogate = nil
        return (Unicode.Scalar(value), 6)
    }
}
