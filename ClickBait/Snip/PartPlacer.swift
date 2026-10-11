import ClickBaitCore
import CoreGraphics
import Foundation

/// Which steps of the parts-tour fix are on (CLAUDE.md "Parts tour", the standard): A keeps
/// every named part (no dropping when finding fails), C colour regions, D line-drawing
/// shapes, E the grid. The benchmark compares them (`CLICKBAIT_TOUR_STEPS`, Debug).
struct TourSteps: Equatable, Sendable, CustomStringConvertible {
    var keepsNames = false
    var colourRegions = false
    var lineRegions = false
    var grid = false

    /// What ships: the steps that passed the benchmark.
    static let shipped = TourSteps(code: "A")
    static let today = TourSteps(code: "today")

    init(code: String) {
        let letters = code.uppercased() == "TODAY" ? "" : code.uppercased()
        keepsNames = letters.contains("A")
        colourRegions = letters.contains("C")
        lineRegions = letters.contains("D")
        grid = letters.contains("E")
    }

    var description: String {
        let code = (keepsNames ? "A" : "") + (colourRegions ? "C" : "") + (lineRegions ? "D" : "") + (grid ? "E" : "")
        return code.isEmpty ? "today" : code
    }

    static var current: TourSteps {
        #if DEBUG
        if let code = ProcessInfo.processInfo.environment["CLICKBAIT_TOUR_STEPS"] { return TourSteps(code: code) }
        #endif
        return shipped
    }

    func allows(_ method: PartMarkMethod) -> Bool {
        switch method {
        case .objects: true
        case .colourRegions: colourRegions
        case .lineRegions: lineRegions
        case .grid: grid
        }
    }
}

/// Where a snip's named parts are, for its tour: on marks found on this Mac — separate things,
/// colour regions, closed shapes or grid cells, chosen by what the picture holds — that the
/// model names by number; names left over keep the model's own guessed spots ("~"), unless
/// those look laid out rather than found (`PartsTour.looksMadeUp`). Shared by asks and the
/// benchmark (`TourBench`), so both run the same path.
enum PartPlacer {
    struct Placement: @unchecked Sendable {  // CGImage is immutable
        /// Close-up pixels, in the explanation's order.
        var stops: [Pointer] = []
        /// The edge around each stop where its mark knows it (close-up pixels); nil → `OutlineFinder`.
        var outlines: [PartOutline?] = []
        var method = "none"
        /// The numbered picture the model named (for the benchmark's renders).
        var marksImage: CGImage?
        var marks: [RegionMark] = []
        var usedReference = false
    }

    /// The long edge of the copy regions are found on (fast, ~65k pixels).
    static let sampleLongEdge = 256.0

    static func place(_ named: [Pointer], explanation: String, view: SnipView, objects: [FoundObject],
                      reference: WikiReference?, provider: any LLMProvider, steps: TourSteps = .current) async -> Placement {
        var seen = Set<String>()
        let unique = Array(named.filter { seen.insert($0.label.lowercased()).inserted }.prefix(PartsTour.maxParts))
        guard !unique.isEmpty else { return Placement() }
        let names = unique.map(\.label)
        var placement = Placement()

        // The methods, best first, for what the picture holds.
        var methods: [PartMarkMethod]
        var pixels: (image: PixelImage, scale: Double)?
        if steps == .today {
            methods = objects.isEmpty ? [] : [.objects]
        } else {
            let usable = PartRegions.objectsAreUsable(objects, nameCount: names.count, marked: view.marked)
            let start = ContinuousClock.now
            let sample = await Task.detached(priority: .userInitiated) { PixelSampler.sample(view.image, longEdge: sampleLongEdge) }.value
            pixels = sample
            var measures: ImageMeasures?
            if let sample {
                measures = PartRegions.measures(sample.image, marked: scaled(view.marked, by: sample.scale))
            }
            methods = measures.map { PartRegions.methods(objectsUsable: usable, measures: $0) } ?? (usable ? [.objects] : [])
            methods = methods.filter { steps.allows($0) }
            Log.ask.notice("""
                Parts: \(objects.count, privacy: .public) thing(s) found for \(names.count, privacy: .public) names \
                (\(usable ? "usable" : objects.isEmpty ? "none" : "not usable: too few, or one covers most of it", privacy: .public)); \
                colours \(measures?.colourVariety ?? -1, privacy: .public) (\(String(format: "%.2f", measures?.colourfulShare ?? 0), privacy: .public)), \
                strokes \(String(format: "%.3f", measures?.strokeDensity ?? 0), privacy: .public) in \(String(describing: ContinuousClock.now - start), privacy: .public); \
                trying \(methods.map(\.rawValue).joined(separator: ", "), privacy: .public) [steps \(steps.description, privacy: .public)]
                """)
        }

        // Mark, then have the model name the marks (at most two tries, for speed).
        var placed: [Pointer] = []
        var tries = 0
        for method in methods where tries < 2 {
            guard !Task.isCancelled else { return placement }
            let start = ContinuousClock.now
            let marks: [RegionMark]
            if method == .objects {
                marks = objects.map { RegionMark(object: $0, outline: nil) }
            } else if let pixels {
                let marked = scaled(view.marked, by: pixels.scale)
                marks = await Task.detached(priority: .userInitiated) {
                    let found: [RegionMark] = switch method {
                    case .colourRegions: PartRegions.colourRegions(pixels.image, marked: marked)
                    case .lineRegions: PartRegions.lineRegions(pixels.image, marked: marked)
                    default: PartRegions.grid(pixels.image, marked: marked)
                    }
                    return found.map { unscaled($0, by: pixels.scale) }
                }.value
            } else {
                continue
            }
            Log.ask.notice("Parts: \(method.rawValue, privacy: .public): \(marks.count, privacy: .public) marks in \(String(describing: ContinuousClock.now - start), privacy: .public)")
            guard steps == .today || PartRegions.marksAreUsable(marks, nameCount: names.count) else {
                Log.ask.notice("Parts: \(marks.count, privacy: .public) \(method.rawValue, privacy: .public) marks for \(names.count, privacy: .public) names; trying the next way")
                continue
            }
            let style: ObjectFinder.MarkStyle = method == .objects ? .above : method == .grid ? .cells : .on
            guard let image = ObjectFinder.marked(view.image, objects: marks.map(\.object), style: style),
                  let encoded = try? await ScreenshotEncoder.encodeInBackground(image), !Task.isCancelled else { continue }
            var request = AskRequest(question: explanation, screenshotJPEG: encoded.jpeg, screenshotWidth: encoded.width,
                                     screenshotHeight: encoded.height, context: ScreenContext())
            request.markNames = names
            request.markCount = marks.count
            request.marksAreCells = method == .grid
            request.reference = reference
            tries += 1
            let asked = ContinuousClock.now
            guard let reply = await AskCoordinator.reply(from: provider, to: request, within: ProviderOperation.labelTourParts.timeout),
                  !Task.isCancelled else {
                Log.ask.notice("Parts: naming the \(method.rawValue, privacy: .public) marks gave no answer")
                continue
            }
            let here = ObjectMarks.placed(names: names, reply: reply, objects: marks.map(\.object))
            Log.ask.notice("""
                Parts: \(here.count, privacy: .public) of \(names.count, privacy: .public) named on \(marks.count, privacy: .public) \
                \(method.rawValue, privacy: .public) marks (\(String(describing: ContinuousClock.now - asked), privacy: .public)): \
                \(here.map { "\($0.label) at \(Int($0.x)),\(Int($0.y))" }.joined(separator: ", "), privacy: .public)
                """)
            guard !here.isEmpty else { continue }
            placed = here
            placement.method = method.rawValue
            placement.marksImage = image
            placement.marks = marks
            placement.usedReference = reference != nil
            break
        }

        // Names no mark took: the model's own guesses, unless they look laid out; today's
        // behaviour dropped them whenever any mark was named.
        var stops = placed
        let left = unique.filter { name in !placed.contains { $0.label.lowercased() == name.label.lowercased() } }
        if !left.isEmpty, steps.keepsNames || placed.isEmpty {
            if PartsTour.looksMadeUp(unique) {
                Log.ask.notice("Parts: \(left.map(\.label).joined(separator: ", "), privacy: .public) left out: the model's positions are laid out in an even row, not found")
            } else {
                let faces = await Task.detached(priority: .userInitiated) { FaceFinder.faces(in: view.image) }.value
                if !faces.isEmpty { Log.ask.notice("Parts: \(faces.count, privacy: .public) face(s) found; people placed on them") }
                let guessed = FaceSnapping.snap(left, to: faces)
                Log.ask.notice("Parts: \(guessed.map(\.label).joined(separator: ", "), privacy: .public) at the model's own guesses (~): no mark was named for them")
                stops += guessed
                if placement.method == "none" { placement.method = "guesses" }
            }
        } else if !left.isEmpty {
            Log.ask.notice("Parts: \(left.map(\.label).joined(separator: ", "), privacy: .public) dropped (no mark named; steps \(steps.description, privacy: .public))")
        }

        // Explanation order; the marks' own outlines where they have them.
        let order = Dictionary(uniqueKeysWithValues: unique.enumerated().map { ($1.label.lowercased(), $0) })
        stops.sort { (order[$0.label.lowercased()] ?? .max) < (order[$1.label.lowercased()] ?? .max) }
        placement.stops = PartsTour.stops(stops, marked: view.marked)
        placement.outlines = placement.stops.map { stop in
            placement.marks.first { abs($0.object.center.x - stop.x) < 0.5 && abs($0.object.center.y - stop.y) < 0.5 }?.outline
        }
        return placement
    }

    /// How much of what was marked is saturated colour (a picture), off the main thread.
    static func colourfulShare(of view: SnipView) async -> Double? {
        await Task.detached(priority: .userInitiated) {
            guard let sample = PixelSampler.sample(view.image, longEdge: sampleLongEdge) else { return nil }
            return PartRegions.measures(sample.image, marked: scaled(view.marked, by: sample.scale)).colourfulShare
        }.value
    }

    static func scaled(_ rect: Rect, by scale: Double) -> Rect {
        Rect(x: rect.x * scale, y: rect.y * scale, width: rect.width * scale, height: rect.height * scale)
    }

    static func unscaled(_ mark: RegionMark, by scale: Double) -> RegionMark {
        let object = mark.object
        return RegionMark(object: FoundObject(center: Point(x: object.center.x / scale, y: object.center.y / scale),
                                              width: object.width / scale, height: object.height / scale, fill: object.fill),
                          outline: mark.outline?.scaled(by: 1 / scale))
    }
}

/// A small RGB copy of a picture for finding regions on (`PartRegions`), and its scale.
enum PixelSampler {
    static func sample(_ image: CGImage, longEdge: Double) -> (image: PixelImage, scale: Double)? {
        let scale = min(1, longEdge / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        // CG's rows run up from the bottom; PixelImage's run down.
        for y in 0..<height {
            let source = (height - 1 - y) * width * 4, target = y * width * 3
            for x in 0..<width {
                rgb[target + x * 3] = bytes[source + x * 4]
                rgb[target + x * 3 + 1] = bytes[source + x * 4 + 1]
                rgb[target + x * 3 + 2] = bytes[source + x * 4 + 2]
            }
        }
        return (PixelImage(width: width, height: height, rgb: rgb), scale)
    }
}
