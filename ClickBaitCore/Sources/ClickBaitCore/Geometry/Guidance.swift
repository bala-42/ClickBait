import Foundation

/// Visual guidance: two blue modes on one API (user's request, 2026-10-17).
///
/// - **Highlight** (mode A): a translucent blue rounded rectangle around a bounded area, a
///   subtle border, an optional label placed around the box so it never covers the box or
///   anything marked critical.
/// - **Arrow** (mode B): a blue arrow whose tip sits exactly on a point (or the near edge of an
///   element), its short tail turned away from nearby controls, an optional pulse and label.
///
/// Both are informational by default (clicks pass through). An actionable guide can be
/// *armed*: the next click on its region (or its element / tip) is caught and the step moves on.
/// Several guides can show at once; the highest priority one is the primary and stays most
/// visible: drawn on top at full strength, the others dimmed where they overlap it, labels kept
/// apart. Pure geometry (AppKit points, y up); the app (`GuidanceController`) resolves targets
/// and draws.
///
///     // A highlight around a region, label placed clear of the toolbar:
///     let box = GuideSpec(kind: .highlight, bounds: Rect(x: 100, y: 300, width: 240, height: 80),
///                         label: "Your recent files", priority: 1)
///     // An arrow at a button's centre, pulsing, armed to advance on its click:
///     let arrow = GuideSpec(kind: .arrow, point: Point(x: 520, y: 640), label: "Click Share",
///                           priority: 2, armed: true, pulse: true)
///     let layout = Guidance.layout([box, arrow], screen: screen, avoid: toolbarRects)
public enum GuideKind: String, Equatable, Sendable { case highlight, arrow }

/// One guide, its target already resolved to screen geometry (`bounds` for an element or
/// region; `point` for an exact spot; an arrow at an element aims at its edge).
public struct GuideSpec: Equatable, Sendable {
    public var kind: GuideKind
    public var bounds: Rect?
    public var point: Point?
    public var label: String?
    /// Higher wins: the primary guide (top, full strength).
    public var priority: Int
    /// Catches the next click on its target, then the step advances.
    public var armed: Bool
    public var pulse: Bool

    public init(kind: GuideKind, bounds: Rect? = nil, point: Point? = nil, label: String? = nil,
                priority: Int = 0, armed: Bool = false, pulse: Bool = false) {
        self.kind = kind
        self.bounds = bounds
        self.point = point
        self.label = label
        self.priority = priority
        self.armed = armed
        self.pulse = pulse
    }
}

/// Where everything of one guide is drawn.
public struct GuideLayout: Equatable, Sendable {
    /// Highlight: the box. Arrow: nil.
    public var box: Rect?
    /// Arrow: the tip (exactly the target) and the tail's end.
    public var tip: Point?
    public var tail: Point?
    public var label: Rect?
    /// 0 = drawn first (bottom); the primary is last.
    public var order: Int
    /// 1 for the primary and anything clear of it; dimmed where it overlaps the primary.
    public var opacity: Double
    public var isPrimary: Bool
}

public enum Guidance {
    /// Room between a highlight and what it marks, and between a box and its label.
    public static let padding = 6.0
    public static let labelGap = 8.0
    public static let cornerRadius = 10.0
    /// The arrow's length tip to tail; and how close a control may come to its line.
    public static let arrowLength = 64.0
    public static let tailClearance = 6.0
    /// The other guides where they overlap the primary.
    public static let dimmedOpacity = 0.45
    /// An armed arrow's click counts this close to its tip (when it has no element bounds).
    public static let tipRadius = 14.0

    /// A highlight's box: the target with `padding`, scaled with the content (zoom) and kept on
    /// the screen. Resizing just means laying out again with the target's new bounds.
    public static func box(for bounds: Rect, scale: Double = 1, screen: Rect) -> Rect {
        let pad = padding * scale
        let raw = Rect(x: bounds.x - pad, y: bounds.y - pad, width: bounds.width + 2 * pad, height: bounds.height + 2 * pad)
        return clamp(raw, into: screen)
    }

    public enum Side: Sendable { case below, above, right, left }

    /// The label around a box: below, then above, right, left (or `sides`' order) — the first
    /// that stays on the screen and covers neither the box, anything in `avoid` (critical
    /// labels), nor `taken` (other guides' labels); then the first that at least keeps off the
    /// box and `taken`; else the first side, kept on the screen.
    public static func label(size: (width: Double, height: Double), around box: Rect, screen: Rect,
                             avoid: [Rect] = [], taken: [Rect] = [],
                             sides: [Side] = [.below, .above, .right, .left]) -> Rect {
        let w = size.width, h = size.height, g = labelGap
        let candidates = sides.map { side in
            switch side {
            case .below: Rect(x: box.midX - w / 2, y: box.minY - g - h, width: w, height: h)  // y up
            case .above: Rect(x: box.midX - w / 2, y: box.maxY + g, width: w, height: h)
            case .right: Rect(x: box.maxX + g, y: box.midY - h / 2, width: w, height: h)
            case .left: Rect(x: box.minX - g - w, y: box.midY - h / 2, width: w, height: h)
            }
        }
        for blocked in [[box] + avoid + taken, [box] + taken] {
            if let fits = candidates.first(where: { candidate in
                contains(screen, candidate) && !blocked.contains { intersects(candidate, $0) }
            }) {
                return fits
            }
        }
        return clamp(candidates[0], into: screen)
    }

    /// An arrow pointing exactly at `tip`: its tail `arrowLength` away, turned to the first
    /// direction (from up-left, round the compass) whose line keeps `tailClearance` from every
    /// rect in `avoid` and stays on the screen.
    public static func arrow(tip: Point, avoid: [Rect] = [], screen: Rect) -> (tail: Point, angle: Double) {
        // Up-left first: like a cursor, it reads as pointing in; then round the compass.
        let angles = [135.0, 90, 45, 180, 0, 225, 270, 315]
        for angle in angles {
            let radians = angle * .pi / 180
            let tail = Point(x: tip.x + cos(radians) * arrowLength, y: tip.y + sin(radians) * arrowLength)
            guard contains(screen, tail) else { continue }
            let clear = avoid.allSatisfy { distance(from: $0, toSegment: tip, tail) >= tailClearance }
            if clear { return (tail, angle) }
        }
        let radians = angles[0] * .pi / 180
        return (Point(x: tip.x + cos(radians) * arrowLength, y: tip.y + sin(radians) * arrowLength), angles[0])
    }

    /// Where an arrow at an element points: the element's edge facing the tail's side (its
    /// centre when no tail direction fits), so the tip touches the control, not its middle.
    public static func tip(for bounds: Rect, avoid: [Rect] = [], screen: Rect) -> Point {
        let centre = Point(x: bounds.midX, y: bounds.midY)
        let (_, angle) = arrow(tip: centre, avoid: avoid.filter { $0 != bounds }, screen: screen)
        let radians = angle * .pi / 180
        let dx = cos(radians), dy = sin(radians)
        // From the centre towards the tail, to the box's edge.
        let tx = dx == 0 ? Double.infinity : (bounds.width / 2) / abs(dx)
        let ty = dy == 0 ? Double.infinity : (bounds.height / 2) / abs(dy)
        let t = min(tx, ty)
        return Point(x: centre.x + dx * t, y: centre.y + dy * t)
    }

    /// All guides at once: the primary (highest priority; the latest on a tie) drawn last at
    /// full strength, the others dimmed where they overlap it; labels placed in priority order
    /// so none covers another, a box, or anything in `avoid`.
    public static func layout(_ guides: [GuideSpec], screen: Rect, scale: Double = 1, avoid: [Rect] = [],
                              labelSize: (String) -> (width: Double, height: Double) = defaultLabelSize) -> [GuideLayout] {
        let ranked = guides.indices.sorted { a, b in
            guides[a].priority != guides[b].priority ? guides[a].priority > guides[b].priority : a > b
        }
        var layouts = [GuideLayout?](repeating: nil, count: guides.count)
        var takenLabels: [Rect] = []
        let boxes = guides.map { guide -> Rect? in
            guard guide.kind == .highlight, let bounds = guide.bounds else { return nil }
            return box(for: bounds, scale: scale, screen: screen)
        }
        var primaryArea: Rect?
        for (rank, index) in ranked.enumerated() {
            let guide = guides[index]
            var layout = GuideLayout(box: nil, tip: nil, tail: nil, label: nil, order: guides.count - 1 - rank,
                                     opacity: 1, isPrimary: rank == 0)
            let others = boxes.enumerated().compactMap { $0.offset == index ? nil : $0.element }
            switch guide.kind {
            case .highlight:
                guard let box = boxes[index] else { continue }
                layout.box = box
                if let text = guide.label {
                    layout.label = label(size: labelSize(text), around: box, screen: screen, avoid: avoid + others, taken: takenLabels)
                }
            case .arrow:
                let target = guide.point ?? guide.bounds.map { tip(for: $0, avoid: avoid, screen: screen) }
                guard let tip = target else { continue }
                let (tail, _) = arrow(tip: tip, avoid: avoid + others, screen: screen)
                layout.tip = tip
                layout.tail = tail
                if let text = guide.label {
                    // Around the whole arrow, on its tail's side first: never on the shaft or the tip.
                    let vertical: [Side] = tail.y >= tip.y ? [.above, .below] : [.below, .above]
                    let horizontal: [Side] = tail.x <= tip.x ? [.left, .right] : [.right, .left]
                    let sides = abs(tail.y - tip.y) >= abs(tail.x - tip.x) ? vertical + horizontal : horizontal + vertical
                    layout.label = label(size: labelSize(text), around: extent(tip, tail), screen: screen,
                                         avoid: avoid + others, taken: takenLabels, sides: sides)
                }
            }
            if let placed = layout.label { takenLabels.append(placed) }
            let area = layout.box ?? layout.tip.flatMap { tip in layout.tail.map { extent(tip, $0) } }
            if rank == 0 {
                primaryArea = area
            } else if let primaryArea, let area, intersects(primaryArea, area) {
                layout.opacity = dimmedOpacity
            }
            layouts[index] = layout
        }
        return layouts.compactMap { $0 }
    }

    /// An armed guide's next click: inside its box (highlight), inside its element, or within
    /// `tipRadius` of its tip (arrow at a point).
    public static func catches(_ click: Point, guide: GuideSpec, layout: GuideLayout) -> Bool {
        guard guide.armed else { return false }
        if let box = layout.box { return contains(box, click) }
        if let bounds = guide.bounds { return contains(bounds, click) }
        if let tip = layout.tip { return hypot(click.x - tip.x, click.y - tip.y) <= tipRadius }
        return false
    }

    /// The label's size at the system's 12 pt: an estimate the app replaces with the real one.
    public static func defaultLabelSize(_ text: String) -> (width: Double, height: Double) {
        (min(Double(text.count) * 6.8 + 20, 280), 24)
    }

    // MARK: Geometry

    static func contains(_ rect: Rect, _ point: Point) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    static func contains(_ outer: Rect, _ inner: Rect) -> Bool {
        inner.minX >= outer.minX && inner.maxX <= outer.maxX && inner.minY >= outer.minY && inner.maxY <= outer.maxY
    }

    static func intersects(_ a: Rect, _ b: Rect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    static func clamp(_ rect: Rect, into screen: Rect) -> Rect {
        let w = min(rect.width, screen.width), h = min(rect.height, screen.height)
        return Rect(x: min(max(rect.x, screen.minX), screen.maxX - w), y: min(max(rect.y, screen.minY), screen.maxY - h),
                    width: w, height: h)
    }

    static func extent(_ a: Point, _ b: Point) -> Rect {
        Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The shortest distance from a segment to a rect (0 if it crosses it).
    static func distance(from rect: Rect, toSegment a: Point, _ b: Point) -> Double {
        if contains(rect, a) || contains(rect, b) { return 0 }
        // Sample the segment: guides are short, and this is exact enough at 1 pt steps.
        let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y)))
        var best = Double.infinity
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let p = Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            let dx = max(rect.minX - p.x, 0, p.x - rect.maxX), dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
            best = min(best, hypot(dx, dy))
            if best == 0 { return 0 }
        }
        return best
    }
}
