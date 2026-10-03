/// How the user marked part of the screen while holding ⌥⌘.
public enum SnipKind: String, Sendable {
    /// Moved the cursor around something without clicking.
    case circled
    /// Clicked and dragged a rectangle.
    case boxed

    /// For the prompt: "the part of the screen the user circled".
    public var verb: String {
        switch self {
        case .circled: "circled"
        case .boxed: "framed with a box"
        }
    }
}

/// What one press of ⌥⌘ turned out to be.
public enum SnipDecision: Equatable, Sendable {
    /// A plain tap (or nothing drawn): explain the highlighted text.
    case tap
    /// `region` and `path` are in global top-left-origin (Quartz) points. `path` is the
    /// traced line, or the box's four corners.
    case snip(SnipKind, region: Rect, path: [Point])
}

/// Follows the cursor and mouse between pressing and releasing ⌥⌘ and decides whether
/// it was a tap, a traced circle or a dragged box. All points are global Quartz points.
public struct SnipTracker: Sendable {
    /// A trace shorter than this is just the hand drifting during a tap.
    public static let minTraceLength = 40.0
    /// A box (or a trace's bounds) smaller than this on both sides isn't a selection.
    public static let minSize = 12.0
    /// Samples closer than this to the previous one are skipped.
    static let sampleSpacing = 2.0

    public private(set) var trace: [Point] = []
    public private(set) var traceLength = 0.0
    public private(set) var boxStart: Point?
    public private(set) var boxEnd: Point?

    public init(start: Point) {
        trace = [start]
    }

    /// The cursor moved without the button down: extend the trace.
    public mutating func cursorMoved(to point: Point) {
        guard boxStart == nil, let last = trace.last else { return }
        let step = Self.distance(last, point)
        guard step >= Self.sampleSpacing else { return }
        trace.append(point)
        traceLength += step
    }

    /// The button went down: from here on it's a box, and the trace is dropped.
    public mutating func mouseDown(at point: Point) {
        boxStart = point
        boxEnd = point
    }

    public mutating func mouseDragged(to point: Point) {
        guard boxStart != nil else { return }
        boxEnd = point
    }

    /// The box being dragged, normalised. Nil before the button goes down.
    public var box: Rect? {
        guard let a = boxStart, let b = boxEnd else { return nil }
        return Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Whether something worth drawing (in red) has been marked yet.
    public var isMarking: Bool { boxStart != nil || traceLength >= Self.minTraceLength / 3 }

    public func decide() -> SnipDecision {
        if let box {
            guard box.width >= Self.minSize || box.height >= Self.minSize else { return .tap }
            let corners = [Point(x: box.x, y: box.y), Point(x: box.x + box.width, y: box.y),
                           Point(x: box.x + box.width, y: box.y + box.height), Point(x: box.x, y: box.y + box.height)]
            return .snip(.boxed, region: box, path: corners)
        }
        guard traceLength >= Self.minTraceLength, let bounds = Self.bounds(of: trace),
              bounds.width >= Self.minSize || bounds.height >= Self.minSize
        else { return .tap }
        return .snip(.circled, region: bounds, path: trace)
    }

    static func bounds(of points: [Point]) -> Rect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func distance(_ a: Point, _ b: Point) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}

/// Where to crop a screenshot around a snip so the model sees the marked area large,
/// with a little of its surroundings for context.
public enum SnipLayout {
    /// Context kept around the region: this fraction of its larger side, at least `minPadding`.
    static let paddingFraction = 0.15
    static let minPadding = 24.0
    /// Tiny regions are widened to this so there's still something around them to read.
    static let minCropSide = 280.0

    /// The crop in display-local points (top-left origin), kept inside the display.
    /// `region` is display-local too.
    public static func crop(around region: Rect, displayWidth: Double, displayHeight: Double) -> Rect {
        let padding = max(minPadding, max(region.width, region.height) * paddingFraction)
        var width = max(region.width + 2 * padding, minCropSide)
        var height = max(region.height + 2 * padding, minCropSide)
        width = min(width, displayWidth)
        height = min(height, displayHeight)
        let centerX = region.x + region.width / 2, centerY = region.y + region.height / 2
        let x = min(max(centerX - width / 2, 0), displayWidth - width)
        let y = min(max(centerY - height / 2, 0), displayHeight - height)
        return Rect(x: x, y: y, width: width, height: height)
    }
}
