import Foundation

/// The shelf note's lists (user's ask, 2026-10-25), as in Notes: Return after a bullet or a
/// checkbox starts the next one (Return on an empty one ends the list), the bullet button
/// bullets the line the caret is on, Tab and ⇧Tab indent, a click on ☐ ticks it. Positions
/// are UTF-16 offsets, as the text view counts.
public enum NoteEditing {
    public struct Edit: Equatable, Sendable {
        public let text: String
        public let caret: Int
    }

    public static let bullet = "• "
    public static let unchecked = "☐ "
    public static let checked = "☑ "
    static let indentUnit = "    "

    /// A line's leading spaces and its list marker, if any.
    struct Line {
        let range: NSRange
        let indent: String
        let marker: String?
        let body: String
    }

    static func line(in text: NSString, at caret: Int) -> Line {
        let range = text.lineRange(for: NSRange(location: min(max(caret, 0), text.length), length: 0))
        var content = text.substring(with: range)
        if content.hasSuffix("\n") { content.removeLast() }
        let indent = String(content.prefix { $0 == " " })
        let rest = String(content.dropFirst(indent.count))
        let marker = [bullet, unchecked, checked].first { rest.hasPrefix($0) }
        return Line(range: range, indent: indent, marker: marker, body: marker.map { String(rest.dropFirst($0.count)) } ?? rest)
    }

    /// Return at `caret`. Nil: a plain new line (not in a list).
    public static func newline(in text: String, at caret: Int) -> Edit? {
        let ns = text as NSString
        let current = line(in: ns, at: caret)
        guard let marker = current.marker else { return nil }
        if current.body.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item: the list ends here; the marker goes.
            let markerRange = NSRange(location: current.range.location + (current.indent as NSString).length, length: (marker as NSString).length)
            let edited = ns.replacingCharacters(in: markerRange, with: "")
            return Edit(text: edited, caret: markerRange.location)
        }
        let next = "\n" + current.indent + (marker == checked ? unchecked : marker)
        return Edit(text: ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: next), caret: caret + (next as NSString).length)
    }

    /// The bullet button: bullets the caret's line, or takes its bullet off.
    public static func toggleBullet(in text: String, at caret: Int) -> Edit {
        toggle(bullet, in: text, at: caret)
    }

    /// The checkbox button: a ☐ on the caret's line, or takes it off.
    public static func toggleCheckbox(in text: String, at caret: Int) -> Edit {
        toggle(unchecked, in: text, at: caret)
    }

    static func toggle(_ wanted: String, in text: String, at caret: Int) -> Edit {
        let ns = text as NSString
        let current = line(in: ns, at: caret)
        let start = current.range.location + (current.indent as NSString).length
        if let marker = current.marker {
            let removing = marker == wanted || (wanted == unchecked && marker == checked)
            let replacement = removing ? "" : wanted
            let change = (replacement as NSString).length - (marker as NSString).length
            return Edit(text: ns.replacingCharacters(in: NSRange(location: start, length: (marker as NSString).length), with: replacement),
                        caret: max(caret + change, start))
        }
        return Edit(text: ns.replacingCharacters(in: NSRange(location: start, length: 0), with: wanted),
                    caret: caret + (wanted as NSString).length)
    }

    /// Tab (or ⇧Tab) on a list line indents it. Nil: not a list line (a plain tab).
    public static func indent(in text: String, at caret: Int, outdent: Bool) -> Edit? {
        let ns = text as NSString
        let current = line(in: ns, at: caret)
        guard current.marker != nil else { return nil }
        if outdent {
            let remove = min((current.indent as NSString).length, (indentUnit as NSString).length)
            guard remove > 0 else { return Edit(text: text, caret: caret) }
            return Edit(text: ns.replacingCharacters(in: NSRange(location: current.range.location, length: remove), with: ""),
                        caret: max(caret - remove, current.range.location))
        }
        return Edit(text: ns.replacingCharacters(in: NSRange(location: current.range.location, length: 0), with: indentUnit),
                    caret: caret + (indentUnit as NSString).length)
    }

    /// A click at `index`: on a ☐ or ☑, ticks or unticks it. Nil: not on a checkbox.
    public static func tick(in text: String, at index: Int) -> String? {
        let ns = text as NSString
        guard index >= 0, index < ns.length else { return nil }
        let symbol = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: index))
        guard symbol == "☐" || symbol == "☑" else { return nil }
        let current = line(in: ns, at: index)
        // Only a line's own marker, not a ☐ typed in the middle of a sentence.
        guard current.marker != nil, index == current.range.location + (current.indent as NSString).length else { return nil }
        return ns.replacingCharacters(in: NSRange(location: index, length: 1), with: symbol == "☐" ? "☑" : "☐")
    }

    /// Text or a link dropped on the note: added as a new line at the end.
    public static func adding(_ dropped: String, to text: String) -> String {
        let piece = dropped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return text }
        if text.isEmpty { return piece }
        return text + (text.hasSuffix("\n") ? "" : "\n") + piece
    }
}
