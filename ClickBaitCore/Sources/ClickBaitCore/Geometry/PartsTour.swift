/// The stops of a snip's parts tour: the parts inside (or just outside) the marked
/// area, each name once, at most `maxParts`. There's nothing to check positions inside
/// an image against, so the pills mark them as approximate ("~ …").
public enum PartsTour {
    public static let maxParts = 10

    /// The marked area is (mostly) text — a paragraph, code, a message — rather than a
    /// figure: no parts to point at. Prose comes back from text recognition as long lines;
    /// diagrams and charts as short labels.
    public static func isMostlyText(_ text: [TextBox], marked: Rect) -> Bool {
        let slackX = marked.width * 0.1, slackY = marked.height * 0.1
        let inside = text.filter {
            $0.center.x >= marked.minX - slackX && $0.center.x <= marked.maxX + slackX
                && $0.center.y >= marked.minY - slackY && $0.center.y <= marked.maxY + slackY
        }
        let characters = inside.reduce(0) { $0 + $1.text.count }
        guard !inside.isEmpty else { return false }
        let averageLine = Double(characters) / Double(inside.count)
        // Prose: long lines. A figure with a caption has many short labels and a few long
        // lines, so the length of the lines decides, not how much text there is.
        return characters >= 50 && averageLine >= 18
    }

    /// `marked` is the area the user circled or boxed, in the parts' pixels.
    public static func stops(_ parts: [Pointer], marked: Rect) -> [Pointer] {
        // Some slack: labels and edges often sit just outside what was circled.
        let slackX = marked.width * 0.1, slackY = marked.height * 0.1
        var seen = Set<String>()
        return Array(parts.filter { part in
            let inside = part.x >= marked.minX - slackX && part.x <= marked.maxX + slackX
                && part.y >= marked.minY - slackY && part.y <= marked.maxY + slackY
            return inside && seen.insert(part.label.lowercased()).inserted
        }.prefix(maxParts))
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

/// Puts named people on real faces. The model reads names well (often from a caption) but
/// places people loosely — it put two of three actors on the same person. Faces come from
/// on-device face detection; a part near a person is moved onto a face, each face used
/// once, matched left to right (the model's left/right order is kept, its exact spots are not).
public enum FaceSnapping {
    /// `faces`: face centres and widths, in the same pixels as `parts`.
    public static func snap(_ parts: [Pointer], to faces: [(center: Point, width: Double)]) -> [Pointer] {
        guard !faces.isEmpty else { return parts }
        // A part counts as a person when it sits around a face: within ~3 face widths across
        // and from just above the face to ~5 face widths below it (the body).
        func isAroundAFace(_ part: Pointer) -> Bool {
            faces.contains { face in
                abs(part.x - face.center.x) <= face.width * 3
                    && part.y >= face.center.y - face.width * 1.5 && part.y <= face.center.y + face.width * 5
            }
        }
        let people = parts.indices.filter { isAroundAFace(parts[$0]) }
        guard !people.isEmpty else { return parts }
        var result = parts
        let byX = people.sorted { parts[$0].x < parts[$1].x }
        let faceOrder = faces.indices.sorted { faces[$0].center.x < faces[$1].center.x }
        if byX.count <= faces.count {
            // Spread the people over the faces in left-to-right order, choosing the run of
            // faces closest to where the model put them.
            var bestStart = 0, bestCost = Double.infinity
            for start in 0...(faces.count - byX.count) {
                let cost = byX.enumerated().reduce(0.0) { total, pair in
                    total + abs(parts[pair.element].x - faces[faceOrder[start + pair.offset]].center.x)
                }
                if cost < bestCost { (bestStart, bestCost) = (start, cost) }
            }
            for (offset, index) in byX.enumerated() {
                let face = faces[faceOrder[bestStart + offset]].center
                result[index].x = face.x
                result[index].y = face.y
            }
        } else {
            // More names than faces: each face goes to the nearest name; the rest stay put.
            var free = Set(byX)
            for faceIndex in faceOrder {
                let face = faces[faceIndex].center
                guard let nearest = free.min(by: { abs(parts[$0].x - face.x) < abs(parts[$1].x - face.x) }) else { break }
                free.remove(nearest)
                result[nearest].x = face.x
                result[nearest].y = face.y
            }
        }
        return result
    }
}
