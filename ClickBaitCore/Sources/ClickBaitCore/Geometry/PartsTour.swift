/// Decides whether the named parts of a snipped thing are trustworthy enough for the
/// companion to tour them. There's nothing to check positions inside an image against
/// (Accessibility doesn't see into pictures), so this keeps only plausible layouts:
/// inside the marked area, distinct names, not piled on top of each other.
public enum PartsTour {
    public static let maxParts = 6
    /// Parts closer than this fraction of the marked area's diagonal count as piled up.
    static let minSpacingFraction = 0.06

    /// `marked` is the area the user circled or boxed, in the same pixels as the parts
    /// (the close-up's). Returns the parts to tour in order, or nil for "list only".
    public static func plan(_ parts: [Pointer], marked: Rect) -> [Pointer]? {
        // A little slack: labels often sit just outside what was circled.
        let slackX = marked.width * 0.1, slackY = marked.height * 0.1
        var seen = Set<String>()
        let usable = parts.filter { part in
            let inside = part.x >= marked.minX - slackX && part.x <= marked.maxX + slackX
                && part.y >= marked.minY - slackY && part.y <= marked.maxY + slackY
            return inside && seen.insert(part.label.lowercased()).inserted
        }.prefix(maxParts)
        guard usable.count >= 2 else { return nil }

        let diagonal = (marked.width * marked.width + marked.height * marked.height).squareRoot()
        let minSpacing = diagonal * minSpacingFraction
        var crowded = 0
        let list = Array(usable)
        for i in list.indices {
            let tooClose = list.indices.contains { j in
                j != i && ((list[i].x - list[j].x) * (list[i].x - list[j].x) + (list[i].y - list[j].y) * (list[i].y - list[j].y)).squareRoot() < minSpacing
            }
            if tooClose { crowded += 1 }
        }
        // A model that can't really place the parts tends to stack them: tour only when
        // most of them stand apart.
        guard crowded * 2 <= list.count else { return nil }
        return list
    }
}

/// Text found in an image by on-device text recognition, with its center in the same
/// pixels as the model's parts.
public struct TextBox: Equatable, Sendable {
    public var text: String
    public var center: Point

    public init(text: String, center: Point) {
        self.text = text
        self.center = center
    }
}

/// Places parts by their printed labels. The model finds the right *shapes* but often
/// swaps the names; where a part's name is written in the image, the written label's
/// position is the truth. Parts whose names aren't printed stay unverified.
public enum PartsMatcher {
    public struct Result: Equatable, Sendable {
        /// Positioned by their printed labels, in the order the answer gave them.
        public var verified: [Pointer]
        /// Named by the model but not found in the image's text.
        public var unverified: [Pointer]
    }

    public static func match(parts: [Pointer], speech: String, text: [TextBox]) -> Result {
        var verified: [Pointer] = []
        var unverified: [Pointer] = []
        var used = Set<Int>()

        func box(for name: String) -> Int? {
            text.indices
                .filter { !used.contains($0) }
                .map { ($0, LabelMatcher.similarity(name, text[$0].text)) }
                .filter { $0.1 >= 0.8 }
                .max { $0.1 < $1.1 }?.0
        }

        for part in parts {
            if let index = box(for: part.label) {
                used.insert(index)
                verified.append(Pointer(x: text[index].center.x, y: text[index].center.y, label: part.label))
            } else {
                unverified.append(part)
            }
        }
        // Printed labels the explanation mentions but the model didn't list as parts.
        let spoken = " " + ImpliedPointer.normalized(speech) + " "
        let mentioned = text.indices
            .filter { !used.contains($0) }
            .compactMap { index -> (Int, String.Index)? in
                let words = ImpliedPointer.normalized(text[index].text)
                guard words.count >= 4, !words.allSatisfy(\.isNumber),
                      let range = spoken.range(of: " " + words + " ") else { return nil }
                return (index, range.lowerBound)
            }
            .sorted { $0.1 < $1.1 }
        for (index, _) in mentioned where verified.count < PartsTour.maxParts {
            used.insert(index)
            verified.append(Pointer(x: text[index].center.x, y: text[index].center.y, label: text[index].text))
        }
        return Result(verified: verified, unverified: unverified)
    }
}
