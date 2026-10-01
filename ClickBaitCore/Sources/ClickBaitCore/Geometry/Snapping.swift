/// An actionable UI element near a pointer, as reported by the accessibility API.
public struct SnapCandidate: Equatable, Sendable {
    /// Accessibility role, e.g. `AXButton`.
    public var role: String
    /// The element's visible name (title, description or value).
    public var label: String
    /// Frame in Quartz global points (top-left origin).
    public var frame: Rect

    public init(role: String, label: String, frame: Rect) {
        self.role = role
        self.label = label
        self.frame = frame
    }

    public var center: Point { Point(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2) }
}

public struct SnapDecision: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case labelMatch = "label match"
        case containingElement = "inside an actionable element"
        case noCandidates = "no actionable elements nearby"
        case noConfidentMatch = "nothing nearby matched the label"
    }

    /// Where the pointer should go (Quartz points).
    public var point: Point
    /// The element snapped to, if any.
    public var candidate: SnapCandidate?
    public var reason: Reason
    public var score: Double
}

/// Decides whether to move a pointer onto a nearby real element.
///
/// Vision models are good at *what* to click and a little off on *where*. The label
/// says what; accessibility knows exactly where things are. A pointer moves only when
/// an element within `radius` clearly matches the label, or when it already sits
/// inside an actionable element. Small elements (buttons, checkboxes) get the pointer
/// at their center; large ones (wide text fields, tables) keep the model's point,
/// just pulled inside their edge, so the pointer never jumps far across them.
public enum Snapper {
    public static let radius = 40.0
    static let minimumSimilarity = 0.5

    public static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXMenuButton", "AXPopUpButton",
        "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
        "AXDisclosureTriangle", "AXTab", "AXSlider", "AXIncrementor", "AXColorWell", "AXDockItem",
    ]

    public static func decide(target: Point, label: String, candidates: [SnapCandidate]) -> SnapDecision {
        let nearby = candidates.filter { distance(from: target, to: $0.frame) <= radius }
        guard !nearby.isEmpty else {
            return SnapDecision(point: target, candidate: nil, reason: .noCandidates, score: 0)
        }

        let scored = nearby.map { candidate -> (SnapCandidate, similarity: Double, score: Double) in
            let similarity = LabelMatcher.similarity(label, candidate.label)
            let closeness = 1 - distance(from: target, to: candidate.frame) / radius
            return (candidate, similarity, similarity * 0.85 + closeness * 0.15)
        }

        if let best = scored.filter({ $0.similarity >= minimumSimilarity }).max(by: { $0.score < $1.score }) {
            return SnapDecision(point: aim(at: best.0, from: target), candidate: best.0, reason: .labelMatch, score: best.score)
        }

        // No label match. If the pointer is already on an actionable element, the model
        // found it visually; settle it there. Prefer the smallest such element.
        let containing = nearby
            .filter { contains($0.frame, target) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        if let containing {
            return SnapDecision(point: aim(at: containing, from: target), candidate: containing, reason: .containingElement, score: 0)
        }
        return SnapDecision(point: target, candidate: nil, reason: .noConfidentMatch, score: 0)
    }

    /// Elements up to this size are "small": the pointer goes to their center.
    public static let smallElement = (width: 160.0, height: 80.0)
    /// How far inside a large element's edge the pointer is kept.
    static let edgeInset = 8.0

    static func aim(at candidate: SnapCandidate, from target: Point) -> Point {
        let frame = candidate.frame
        if frame.width <= smallElement.width, frame.height <= smallElement.height {
            return candidate.center
        }
        let insetX = min(edgeInset, frame.width / 2), insetY = min(edgeInset, frame.height / 2)
        return Point(
            x: min(max(target.x, frame.minX + insetX), frame.maxX - insetX),
            y: min(max(target.y, frame.minY + insetY), frame.maxY - insetY)
        )
    }

    /// 0 when the point is inside the rect.
    static func distance(from point: Point, to rect: Rect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func contains(_ rect: Rect, _ point: Point) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
}

/// Fuzzy comparison between the model's label ("Share button") and an element's
/// accessible name ("Share…").
public enum LabelMatcher {
    /// Words models tack on ("Share button") that usually aren't in the element's name.
    static let fillerWords: Set<String> = ["button", "icon", "link", "menu", "item", "tab", "the", "a", "an", "field", "box"]
    /// A match found only after dropping filler words counts a little less, so a real
    /// "Copy Link" beats "Copy" when the model said "Copy Link".
    static let fillerStrippedWeight = 0.85

    /// How well the model's `label` names an element called `elementName` (0…1).
    public static func similarity(_ label: String, _ elementName: String) -> Double {
        let element = normalize(elementName)
        let raw = compare(normalize(label), element)
        let stripped = compare(normalize(label, droppingFiller: true), element) * fillerStrippedWeight
        return max(raw, stripped)
    }

    private static func compare(_ left: String, _ right: String) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        if left.contains(right) || right.contains(left) {
            let shorter = Double(min(left.count, right.count)), longer = Double(max(left.count, right.count))
            return 0.7 + 0.25 * shorter / longer
        }
        let leftWords = Set(left.split(separator: " ")), rightWords = Set(right.split(separator: " "))
        let jaccard = Double(leftWords.intersection(rightWords).count) / Double(leftWords.union(rightWords).count)
        return max(jaccard, editSimilarity(left, right))
    }

    static func normalize(_ text: String, droppingFiller: Bool = false) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "…", with: " ")
        let cleaned = String(lowered.unicodeScalars.map { $0.properties.isAlphabetic || $0.properties.numericType != nil ? Character($0) : " " })
        let words = cleaned.split(separator: " ").filter { !droppingFiller || !fillerWords.contains(String($0)) }
        return words.joined(separator: " ")
    }

    /// 1 − Levenshtein distance / longer length.
    static func editSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1] ? previous[j - 1] : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}
