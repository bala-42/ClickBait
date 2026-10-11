import Foundation

/// The parts-tour benchmark: pictures (outside git, by path), their parts' boxes, and the
/// score of a tour against them. Every change to tours is run against it (CLAUDE.md).
public struct TourBenchmark: Codable, Sendable {
    public var images: [Image]

    public struct Image: Codable, Sendable {
        public var name: String
        /// The picture type, so results can be reported per type.
        public var type: String
        public var path: String
        /// Ignore anything at or below this y (original pixels), e.g. a watermark banner.
        public var ignoreBelowY: Double?
        /// Words never to be named or marked (watermarks).
        public var neverNamed: [String]?
        public var parts: [Part]
    }

    public struct Part: Codable, Sendable {
        /// The part's name and its synonyms ("large intestine", "colon").
        public var names: [String]
        /// Boxes x0, y0, x1, y1 in the original picture's pixels; a stop in any one counts.
        public var boxes: [[Double]]
        /// Boxes that don't count even inside `boxes` (the cerebrum's box minus the coloured
        /// centre of a brain section). No slack.
        public var exclude: [[Double]]?
    }

    public static func load(from url: URL) throws -> TourBenchmark {
        try JSONDecoder().decode(TourBenchmark.self, from: Data(contentsOf: url))
    }
}

/// How a tour did on one benchmark picture.
public struct TourScore: Equatable, Sendable {
    /// Names the explanation gave (parts it named).
    public var named: [String]
    /// Stops placed right (their point in one of the part's boxes, with slack), wrong, and
    /// stops whose name matches no part in the boxes (neither right nor wrong).
    public var right: [String]
    public var wrong: [String]
    public var unknown: [String]
    /// Parts in the boxes that were named but got no stop.
    public var dropped: [String]

    public var toured: Int { right.count + wrong.count + unknown.count }
    /// Right out of the stops that could be judged.
    public var placedRight: Double? {
        let judged = right.count + wrong.count
        return judged == 0 ? nil : Double(right.count) / Double(judged)
    }

    /// Slack around a box: 4% of the picture's longer side.
    public static let slack = 0.04

    /// Scores `stops` (points in the original picture's pixels) for `image`, given the
    /// names the explanation gave.
    public static func score(stops: [Pointer], named: [String], image: TourBenchmark.Image,
                             width: Double, height: Double) -> TourScore {
        let pad = slack * max(width, height)
        var score = TourScore(named: named, right: [], wrong: [], unknown: [], dropped: [])
        for stop in stops {
            guard let part = part(named: stop.label, in: image) else {
                score.unknown.append(stop.label)
                continue
            }
            let inBox = part.boxes.contains { box in
                box.count == 4 && stop.x >= box[0] - pad && stop.x <= box[2] + pad && stop.y >= box[1] - pad && stop.y <= box[3] + pad
            }
            let excluded = (part.exclude ?? []).contains { box in
                box.count == 4 && stop.x >= box[0] && stop.x <= box[2] && stop.y >= box[1] && stop.y <= box[3]
            }
            let inside = inBox && !excluded
            if inside { score.right.append(stop.label) } else { score.wrong.append(stop.label) }
        }
        let touredParts = Set(stops.compactMap { part(named: $0.label, in: image)?.names.first })
        for name in named {
            guard let part = part(named: name, in: image), let key = part.names.first, !touredParts.contains(key),
                  !score.dropped.contains(key) else { continue }
            score.dropped.append(key)
        }
        return score
    }

    /// The box part a name means, matched loosely: case, "the", "~", plurals and word order
    /// within a name don't matter, and either name may contain the other ("left lung").
    public static func part(named name: String, in image: TourBenchmark.Image) -> TourBenchmark.Part? {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return nil }
        // Exact first, then containment (longest synonym first, so "small intestine" isn't "intestine").
        if let exact = image.parts.first(where: { $0.names.contains { normalized($0) == wanted } }) { return exact }
        let candidates = image.parts.flatMap { part in part.names.map { (part, normalized($0)) } }
            .filter { !$0.1.isEmpty && (wanted.contains($0.1) || $0.1.contains(wanted)) }
            .sorted { $0.1.count > $1.1.count }
        return candidates.first?.0
    }

    static func normalized(_ name: String) -> String {
        let lowered = name.lowercased().replacingOccurrences(of: "~", with: " ")
        let raw: [String] = lowered.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let skipped: Set<String> = ["the", "a", "an"]
        let words: [String] = raw.filter { !skipped.contains($0) }.map(singular)
        return words.joined(separator: " ")
    }

    static func singular(_ word: String) -> String {
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        let keeps = word.hasSuffix("ss") || word.hasSuffix("us") || word.hasSuffix("is")
        if word.hasSuffix("s"), !keeps, word.count > 3 { return String(word.dropLast()) }
        return word
    }
}
