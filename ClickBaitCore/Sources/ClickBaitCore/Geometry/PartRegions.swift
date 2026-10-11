import Foundation

/// A small RGB copy of a snip's close-up (rows top to bottom, 3 bytes a pixel), for finding
/// its parts on this Mac. The app makes it (≤ 256 px on its long edge) and scales back.
public struct PixelImage: Sendable {
    public let width: Int
    public let height: Int
    public let rgb: [UInt8]

    public init(width: Int, height: Int, rgb: [UInt8]) {
        precondition(rgb.count == width * height * 3)
        self.width = width
        self.height = height
        self.rgb = rgb
    }

    func colour(_ index: Int) -> RGB {
        RGB(r: Int(rgb[index * 3]), g: Int(rgb[index * 3 + 1]), b: Int(rgb[index * 3 + 2]))
    }
}

/// One pixel's colour, 0…255 a channel.
struct RGB: Equatable {
    var r: Int, g: Int, b: Int
}

/// A numbered mark for the parts tour: the thing (centre = its best interior point, box, how
/// solidly it fills the box) and its outline from that point, in the image's pixels.
public struct RegionMark: Equatable, Sendable {
    public var object: FoundObject
    public var outline: PartOutline?

    public init(object: FoundObject, outline: PartOutline?) {
        self.object = object
        self.outline = outline
    }
}

/// How to find the parts of a circled picture (CLAUDE.md "Parts tour", the standard): by what
/// it holds, chosen from cheap measures, so every kind of picture gets marks the model can name.
public enum PartMarkMethod: String, Sendable, CaseIterable {
    /// Separate things (planets, objects, people): Vision's subject masks (`ObjectFinder`).
    case objects
    /// Connected coloured diagrams (anatomy, cut-aways, maps, cells): colour regions.
    case colourRegions
    /// Line drawings, single-colour pictures: the closed shapes the strokes make.
    case lineRegions
    /// Nothing else gave usable marks: numbered cells.
    case grid
}

public struct ImageMeasures: Equatable, Sendable {
    /// Distinct hues covering ≥ 2% of the saturated pixels (12 bins).
    public var colourVariety: Int
    /// Share of the marked area that is saturated colour.
    public var colourfulShare: Double
    /// Share of the marked area that is dark strokes.
    public var strokeDensity: Double
}

public enum PartRegions {
    public static let maxMarks = ObjectMarks.maxMarks

    // MARK: - The method

    /// Whether Vision's separate things can stand in for the named parts: enough of them
    /// (at least half as many as names, and two), and none covering most of what was marked
    /// — one blob must never stand in for one part (the 2026-10-11 organ diagram: 1 thing for
    /// 8 names, the whole body, named "Stomach").
    public static func objectsAreUsable(_ objects: [FoundObject], nameCount: Int, marked: Rect) -> Bool {
        let area = max(marked.width * marked.height, 1)
        guard objects.count >= max(2, (nameCount + 1) / 2) else { return false }
        return !objects.contains { $0.width * $0.height > area * 0.4 }
    }

    /// The methods worth trying for a picture, best first; `grid` always comes last.
    public static func methods(objectsUsable: Bool, measures: ImageMeasures) -> [PartMarkMethod] {
        var methods: [PartMarkMethod] = []
        if objectsUsable { methods.append(.objects) }
        if measures.colourVariety >= 3, measures.colourfulShare >= 0.05 { methods.append(.colourRegions) }
        if measures.strokeDensity >= 0.015 { methods.append(.lineRegions) }
        methods.append(.grid)
        return methods
    }

    /// Enough marks to be worth asking the model about.
    public static func marksAreUsable(_ marks: [RegionMark], nameCount: Int) -> Bool {
        marks.count >= min(max(nameCount, 1), 3)
    }

    // MARK: - Measures

    public static func measures(_ image: PixelImage, marked: Rect) -> ImageMeasures {
        let background = backgroundColour(image)
        var hues = [Int](repeating: 0, count: 12)
        var saturated = 0, strokes = 0, total = 0
        forEachPixel(in: image, within: marked) { index in
            total += 1
            let c = image.colour(index)
            if isStroke(c) { strokes += 1; return }
            guard distance(c, background) >= backgroundTolerance else { return }
            let (hue, saturation, _) = hsv(c)
            if saturation >= 0.2 {
                saturated += 1
                hues[min(Int(hue * 12), 11)] += 1
            }
        }
        let variety = saturated == 0 ? 0 : hues.filter { Double($0) >= Double(saturated) * 0.02 }.count
        return ImageMeasures(colourVariety: variety, colourfulShare: Double(saturated) / Double(max(total, 1)),
                             strokeDensity: Double(strokes) / Double(max(total, 1)))
    }

    // MARK: - Colour regions (connected coloured diagrams)

    /// Regions of similar colour inside what was marked: grown from each unlabelled pixel,
    /// joined with similar neighbours (also across the black outline strokes between them),
    /// without background, strokes, specks, thin slivers or whole silhouettes; at most 20,
    /// numbered left to right, each at its most interior point.
    public static func colourRegions(_ image: PixelImage, marked: Rect) -> [RegionMark] {
        let width = image.width, height = image.height, count = width * height
        let background = backgroundColour(image)
        // 0 outside / background, 1 stroke, 2 colour.
        var kind = [UInt8](repeating: 0, count: count)
        forEachPixel(in: image, within: marked) { index in
            let c = image.colour(index)
            if isStroke(c) { kind[index] = 1 } else if distance(c, background) >= backgroundTolerance { kind[index] = 2 }
        }
        var label = [Int32](repeating: -1, count: count)
        var sums: [(r: Double, g: Double, b: Double, n: Double)] = []
        var queue = [Int]()
        queue.reserveCapacity(count)
        for seed in 0..<count where kind[seed] == 2 && label[seed] < 0 {
            let id = Int32(sums.count)
            var sum = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
            queue.removeAll(keepingCapacity: true)
            queue.append(seed)
            label[seed] = id
            var head = 0
            while head < queue.count {
                let index = queue[head]; head += 1
                let c = image.colour(index)
                sum.r += Double(c.r); sum.g += Double(c.g); sum.b += Double(c.b); sum.n += 1
                let mean = (r: sum.r / sum.n, g: sum.g / sum.n, b: sum.b / sum.n)
                let x = index % width, y = index / width
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let next = ny * width + nx
                    guard kind[next] == 2, label[next] < 0 else { continue }
                    let n = image.colour(next)
                    let dr = Double(n.r) - mean.r, dg = Double(n.g) - mean.g, db = Double(n.b) - mean.b
                    guard (dr * dr + dg * dg + db * db).squareRoot() < growTolerance else { continue }
                    label[next] = id
                    queue.append(next)
                }
            }
            sums.append(sum)
        }
        guard !sums.isEmpty else { return [] }

        // Join similar neighbours: touching, or on either side of a stroke.
        var parent = Array(0..<sums.count)
        func root(_ a: Int) -> Int { var a = a; while parent[a] != a { parent[a] = parent[parent[a]]; a = parent[a] }; return a }
        func meanColour(_ id: Int) -> RGB {
            let s = sums[id]; return RGB(r: Int(s.r / s.n), g: Int(s.g / s.n), b: Int(s.b / s.n))
        }
        func join(_ a: Int, _ b: Int) {
            let ra = root(a), rb = root(b)
            guard ra != rb, distance(meanColour(a), meanColour(b)) < mergeTolerance else { return }
            parent[max(ra, rb)] = min(ra, rb)
        }
        for index in 0..<count {
            let x = index % width, y = index / width
            if label[index] >= 0 {
                let a = Int(label[index])
                if x + 1 < width, label[index + 1] >= 0 { join(a, Int(label[index + 1])) }
                if y + 1 < height, label[index + width] >= 0 { join(a, Int(label[index + width])) }
            } else if kind[index] == 1 {
                // Regions within 2 px of this stroke pixel, on its two sides.
                var near: [Int] = []
                for dy in -2...2 { for dx in -2...2 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let l = label[ny * width + nx]
                    if l >= 0, !near.contains(Int(l)) { near.append(Int(l)) }
                } }
                for i in near.indices { for j in near.indices where j > i { join(near[i], near[j]) } }
            }
        }
        var region = [Int32](repeating: -1, count: count)
        for index in 0..<count where label[index] >= 0 { region[index] = Int32(root(Int(label[index]))) }
        return marks(from: region, width: width, height: height, marked: marked)
    }

    // MARK: - Line regions (line drawings, single-colour pictures)

    /// The closed shapes the strokes make: everything darker than halfway between the
    /// background and the darkest ink is a stroke (thickened by a pixel so small gaps close),
    /// and each enclosed area that doesn't reach the picture's edge is a shape.
    public static func lineRegions(_ image: PixelImage, marked: Rect) -> [RegionMark] {
        let width = image.width, height = image.height, count = width * height
        let lumas = (0..<count).map { luma(image.colour($0)) }
        let background = luma(backgroundColour(image))
        let darkest = lumas.sorted()[min(count - 1, count / 50)]
        guard background - darkest > 40 else { return [] }  // no ink to speak of
        let threshold = (background + darkest) / 2
        var stroke = lumas.map { $0 < threshold }
        // Close one-pixel gaps.
        var thick = stroke
        for index in 0..<count where stroke[index] {
            let x = index % width, y = index / width
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                thick[ny * width + nx] = true
            }
        }
        stroke = thick
        var region = [Int32](repeating: -1, count: count)
        var next: Int32 = 0
        var queue = [Int]()
        for seed in 0..<count where !stroke[seed] && region[seed] == -1 {
            queue.removeAll(keepingCapacity: true)
            queue.append(seed)
            region[seed] = next
            var head = 0, touchesEdge = false
            while head < queue.count {
                let index = queue[head]; head += 1
                let x = index % width, y = index / width
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 { touchesEdge = true }
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let n = ny * width + nx
                    guard !stroke[n], region[n] == -1 else { continue }
                    region[n] = next
                    queue.append(n)
                }
            }
            if touchesEdge { for index in queue { region[index] = -2 } }  // the outside, not a shape
            next += 1
        }
        for index in 0..<count where region[index] == -2 { region[index] = -1 }
        return marks(from: region, width: width, height: height, marked: marked)
    }

    // MARK: - Grid (the fallback)

    /// Numbered cells over what was marked (about 4 across the shorter side), each marked at
    /// the most interior point of the biggest coloured area in it, or its centre.
    public static func grid(_ image: PixelImage, marked: Rect) -> [RegionMark] {
        let short = min(marked.width, marked.height), long = max(marked.width, marked.height)
        let across = 4, along = min(max(Int((Double(across) * long / max(short, 1)).rounded()), 3), 6)
        let columns = marked.width >= marked.height ? along : across
        let rows = marked.width >= marked.height ? across : along
        let cellWidth = marked.width / Double(columns), cellHeight = marked.height / Double(rows)
        let background = backgroundColour(image)
        var marks: [RegionMark] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let cell = Rect(x: marked.minX + Double(column) * cellWidth, y: marked.minY + Double(row) * cellHeight,
                                width: cellWidth, height: cellHeight)
                // The cell's non-background, non-stroke pixels: their most interior point.
                var inside = [Bool](repeating: false, count: image.width * image.height)
                var any = false
                forEachPixel(in: image, within: cell) { index in
                    let c = image.colour(index)
                    if !isStroke(c), distance(c, background) >= backgroundTolerance { inside[index] = true; any = true }
                }
                let centre = any ? interiorPoint(of: inside, width: image.width, height: image.height, box: cell)
                    : Point(x: cell.x + cell.width / 2, y: cell.y + cell.height / 2)
                marks.append(RegionMark(object: FoundObject(center: centre, width: cell.width, height: cell.height, fill: 1),
                                        outline: nil))
            }
        }
        return marks
    }

    /// Grid cells keep their reading order (row by row), the others are numbered left to right.
    public static func gridShape(for marks: [RegionMark]) -> (columns: Int, rows: Int)? {
        guard let first = marks.first?.object else { return nil }
        let columns = Set(marks.map { Int(($0.object.center.x - first.center.x) / max(first.width, 1)) }).count
        return (columns, marks.count / max(columns, 1))
    }

    // MARK: - Shared

    static let backgroundTolerance = 40.0
    static let growTolerance = 26.0
    static let mergeTolerance = 20.0

    /// Regions (ids per pixel, −1 none) → marks: specks, slivers and silhouettes dropped, the
    /// biggest 20 kept, numbered left to right.
    static func marks(from region: [Int32], width: Int, height: Int, marked: Rect) -> [RegionMark] {
        let markedArea = max(marked.width * marked.height, 1)
        var stats: [Int32: (n: Int, minX: Int, minY: Int, maxX: Int, maxY: Int)] = [:]
        for index in 0..<region.count where region[index] >= 0 {
            let x = index % width, y = index / width
            if var s = stats[region[index]] {
                s.n += 1; s.minX = min(s.minX, x); s.minY = min(s.minY, y); s.maxX = max(s.maxX, x); s.maxY = max(s.maxY, y)
                stats[region[index]] = s
            } else {
                stats[region[index]] = (1, x, y, x, y)
            }
        }
        let kept = stats.filter { _, s in
            let boxWidth = Double(s.maxX - s.minX + 1), boxHeight = Double(s.maxY - s.minY + 1)
            let fill = Double(s.n) / (boxWidth * boxHeight)
            let speck = Double(s.n) < max(12, markedArea * 0.002)
            let sliver = fill < 0.15 || min(boxWidth, boxHeight) < 3
            let silhouette = Double(s.n) > markedArea * 0.2 && boxWidth * boxHeight > markedArea * 0.5
            return !speck && !sliver && !silhouette
        }
        .sorted { $0.value.n > $1.value.n }
        .prefix(maxMarks)
        let marks = kept.map { id, s -> RegionMark in
            let inside = region.map { $0 == id }
            let box = Rect(x: Double(s.minX), y: Double(s.minY), width: Double(s.maxX - s.minX + 1), height: Double(s.maxY - s.minY + 1))
            let centre = interiorPoint(of: inside, width: width, height: height, box: box)
            let object = FoundObject(center: centre, width: box.width, height: box.height, fill: Double(s.n) / (box.width * box.height))
            return RegionMark(object: object, outline: PartOutline.from(mask: inside, width: width, height: height, seed: centre))
        }
        return marks.sorted { $0.object.center.x < $1.object.center.x }
    }

    /// The point deepest inside a shape (furthest from its edge, 3–4 chamfer distance),
    /// within `box`, at its pixel's centre.
    static func interiorPoint(of inside: [Bool], width: Int, height: Int, box: Rect) -> Point {
        let x0 = max(0, Int(box.minX)), y0 = max(0, Int(box.minY))
        let x1 = min(width - 1, Int(box.maxX.rounded(.up)) - 1), y1 = min(height - 1, Int(box.maxY.rounded(.up)) - 1)
        guard x1 >= x0, y1 >= y0 else { return Point(x: box.x + box.width / 2, y: box.y + box.height / 2) }
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        let far = Int32.max / 4
        var depth = [Int32](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w where inside[(y + y0) * width + x + x0] { depth[y * w + x] = far } }
        func at(_ x: Int, _ y: Int) -> Int32 { x < 0 || y < 0 || x >= w || y >= h ? 0 : depth[y * w + x] }
        for y in 0..<h { for x in 0..<w where depth[y * w + x] > 0 {
            depth[y * w + x] = min(depth[y * w + x], at(x - 1, y) + 3, at(x, y - 1) + 3, at(x - 1, y - 1) + 4, at(x + 1, y - 1) + 4)
        } }
        var best = (value: Int32(-1), x: 0, y: 0)
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) where depth[y * w + x] > 0 {
            depth[y * w + x] = min(depth[y * w + x], at(x + 1, y) + 3, at(x, y + 1) + 3, at(x + 1, y + 1) + 4, at(x - 1, y + 1) + 4)
            if depth[y * w + x] > best.value { best = (depth[y * w + x], x, y) }
        } }
        guard best.value > 0 else { return Point(x: box.x + box.width / 2, y: box.y + box.height / 2) }
        return Point(x: Double(best.x + x0) + 0.5, y: Double(best.y + y0) + 0.5)
    }

    /// The commonest colour along the picture's edge (5-bit bins), averaged: its background.
    static func backgroundColour(_ image: PixelImage) -> RGB {
        var bins: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        func add(_ index: Int) {
            let c = image.colour(index)
            let key = (c.r >> 3) << 10 | (c.g >> 3) << 5 | (c.b >> 3)
            var bin = bins[key] ?? (0, 0, 0, 0)
            bin.n += 1; bin.r += c.r; bin.g += c.g; bin.b += c.b
            bins[key] = bin
        }
        for x in 0..<image.width { add(x); add((image.height - 1) * image.width + x) }
        for y in 0..<image.height { add(y * image.width); add(y * image.width + image.width - 1) }
        guard let top = bins.values.max(by: { $0.n < $1.n }) else { return RGB(r: 255, g: 255, b: 255) }
        return RGB(r: top.r / top.n, g: top.g / top.n, b: top.b / top.n)
    }

    /// Dark outline ink: very dark, or dark and greyish.
    static func isStroke(_ c: RGB) -> Bool {
        let l = luma(c)
        return l < 60 || (l < 100 && hsv(c).saturation < 0.25)
    }

    static func luma(_ c: RGB) -> Int { (299 * c.r + 587 * c.g + 114 * c.b) / 1000 }

    static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = Double(a.r - b.r), dg = Double(a.g - b.g), db = Double(a.b - b.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    static func hsv(_ c: RGB) -> (hue: Double, saturation: Double, value: Double) {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        guard delta > 0 else { return (0, 0, high) }
        var hue: Double
        if high == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == g { hue = (b - r) / delta + 2 }
        else { hue = (r - g) / delta + 4 }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (min(hue, 0.9999), delta / high, high)
    }

    static func forEachPixel(in image: PixelImage, within area: Rect, _ body: (Int) -> Void) {
        let x0 = max(0, Int(area.minX)), y0 = max(0, Int(area.minY))
        let x1 = min(image.width, Int(area.maxX.rounded(.up))), y1 = min(image.height, Int(area.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return }
        for y in y0..<y1 { for x in x0..<x1 { body(y * image.width + x) } }
    }
}
