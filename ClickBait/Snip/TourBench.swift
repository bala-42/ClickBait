#if DEBUG
import AppKit
import ClickBaitCore
import CoreText
import ImageIO

/// The parts-tour benchmark (CLAUDE.md "Parts tour"): each picture in the boxes file, fed as
/// a snip close-up of the whole picture (as if the user circled it all), through the real
/// parts path, scored against its boxes. Debug only; uses the local model:
///
///     CLICKBAIT_TOUR_BENCH=docs/tour-benchmark/boxes.json CLICKBAIT_TOUR_BENCH_OUT=<folder> \
///     CLICKBAIT_TOUR_STEPS=A CLICKBAIT_TOUR_RUNS=2 …/ClickBait.app/Contents/MacOS/ClickBait
///
/// Writes report-<steps>.md and renders (numbered marks, stops, boxes) and quits. It runs
/// before anything else starts, so a ClickBait already running is left alone.
@MainActor
enum TourBench {
    static func runIfRequested(settings: AppSettings) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let boxesPath = environment["CLICKBAIT_TOUR_BENCH"] else { return false }
        let out = URL(fileURLWithPath: environment["CLICKBAIT_TOUR_BENCH_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
        let runs = Int(environment["CLICKBAIT_TOUR_RUNS"] ?? "") ?? 2
        let only = environment["CLICKBAIT_TOUR_ONLY"]
        let steps = TourSteps.current
        Task {
            do {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                let benchmark = try TourBenchmark.load(from: URL(fileURLWithPath: boxesPath))
                let provider = settings.makeProvider()
                var report = ["# Parts-tour benchmark — steps \(steps), \(Date.now.formatted(date: .abbreviated, time: .shortened))", ""]
                var byType: [String: (right: Int, judged: Int)] = [:]
                for image in benchmark.images where only == nil || image.name == only {
                    for run in 1...runs {
                        let line = await bench(image, run: run, steps: steps, provider: provider, out: out)
                        report.append(line.text)
                        print(line.text)
                        var total = byType[image.type] ?? (0, 0)
                        total.right += line.score?.right.count ?? 0
                        total.judged += (line.score?.right.count ?? 0) + (line.score?.wrong.count ?? 0)
                        byType[image.type] = total
                    }
                }
                report.append("")
                report.append("## By picture type")
                for (type, total) in byType.sorted(by: { $0.key < $1.key }) {
                    let share = total.judged == 0 ? "—" : "\(Int((Double(total.right) / Double(total.judged) * 100).rounded()))%"
                    report.append("- \(type): \(total.right)/\(total.judged) stops right (\(share))")
                }
                let text = report.joined(separator: "\n")
                try text.write(to: out.appending(path: "report-\(steps).md"), atomically: true, encoding: .utf8)
                print(text)
            } catch {
                print("Tour bench failed: \(error)")
            }
            exit(0)
        }
        return true
    }

    private struct Line {
        var text: String
        var score: TourScore?
    }

    private static func bench(_ entry: TourBenchmark.Image, run: Int, steps: TourSteps, provider: OllamaProvider, out: URL) async -> Line {
        guard let original = load(entry.path, ignoreBelowY: entry.ignoreBelowY) else {
            return Line(text: "- \(entry.name) run \(run): couldn't open \(entry.path)")
        }
        let scale = SnipView.longEdge / Double(max(original.width, original.height))
        guard let closeUp = resized(original, by: scale) else { return Line(text: "- \(entry.name): couldn't scale") }
        let whole = Rect(x: 0, y: 0, width: Double(closeUp.width), height: Double(closeUp.height))
        let view = SnipView(image: closeUp, crop: whole, marked: whole, primaryDisplayHeight: whole.height)
        let flag = ObjectFinder.CancellationFlag()
        let reading = Task.detached { await TextReader.read(closeUp) }
        let objects = Task.detached(priority: .userInitiated) { ObjectFinder.objects(in: closeUp, marked: whole, cancellation: flag) }

        // The explanation, as a snip asks for it.
        guard let encoded = try? ScreenshotEncoder.encode(closeUp) else { return Line(text: "- \(entry.name): couldn't encode") }
        let request = AskRequest(question: "", screenshotJPEG: encoded.jpeg, screenshotWidth: encoded.width,
                                 screenshotHeight: encoded.height, context: ScreenContext(), snip: .circled)
        let asked = ContinuousClock.now
        guard let reply = await AskCoordinator.reply(from: provider, to: request, within: .seconds(90)) else {
            return Line(text: "- \(entry.name) run \(run): no explanation")
        }
        let explained = ContinuousClock.now
        let parsed = ResponseParser.parse(reply, imageWidth: closeUp.width, imageHeight: closeUp.height, scale: provider.coordinateScale)
        var parts = parsed.response.parts
        let speech = ExplanationCleaner.limited(ExplanationCleaner.clean(parsed.response.speech))
        let rambled = reply.count > 1_500 || parsed.usedFallback
        let boxes = await TextReader.read(reading, within: .milliseconds(1500))
        let mostlyText = PartsTour.isMostlyText(boxes, marked: whole, colourfulShare: await PartPlacer.colourfulShare(of: view))
        let printed = PartsMatcher.match(parts: parts, speech: "", text: boxes).verified
        let labelled = mostlyText || (!printed.isEmpty && printed.count * 2 >= max(parts.count, 1))
        var placing = ContinuousClock.now
        if !labelled, parts.isEmpty {
            var look = AskRequest(question: speech, screenshotJPEG: encoded.jpeg, screenshotWidth: encoded.width,
                                  screenshotHeight: encoded.height, context: ScreenContext())
            look.listParts = true
            if let again = await AskCoordinator.reply(from: provider, to: look, within: ProviderOperation.labelTourParts.timeout) {
                parts = ResponseParser.parse(again, imageWidth: closeUp.width, imageHeight: closeUp.height, scale: provider.coordinateScale).response.parts
            }
            placing = ContinuousClock.now
        }
        let named = parts.map(\.label)
        guard !labelled else {
            return Line(text: "- \(entry.name) run \(run): labelled or text (\(printed.count) of \(parts.count) names printed): no tour")
        }
        let placement = await PartPlacer.place(parts, explanation: speech, view: view, objects: await objects.value,
                                               reference: nil, provider: provider, steps: steps)
        // Outlines as the tour would find them, for the time to the first stop.
        _ = placement.stops.enumerated().map { index, stop in
            placement.outlines.indices.contains(index) && placement.outlines[index] != nil ? nil : view.outlines(at: [stop]).first
        }
        let firstStop = ContinuousClock.now - placing

        // Score in the original picture's pixels.
        let stops = placement.stops.map { Pointer(x: $0.x / scale, y: $0.y / scale, label: $0.label) }
        let score = TourScore.score(stops: stops, named: named, image: entry, width: Double(original.width), height: Double(original.height))
        let forbidden = (entry.neverNamed ?? []).filter { word in named.contains { $0.localizedCaseInsensitiveContains(word) } }
        save(render(closeUp, entry: entry, scale: scale, stops: placement.stops), to: out.appending(path: "\(entry.name)-\(steps)-run\(run).png"))
        if let marks = placement.marksImage { save(marks, to: out.appending(path: "\(entry.name)-\(steps)-run\(run)-marks.png")) }

        let share = score.placedRight.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        let summary = """
            - **\(entry.name)** (\(entry.type)) run \(run): named \(named.count), toured \(score.toured) by \(placement.method), \
            right \(score.right.count)/\(score.right.count + score.wrong.count) (\(share)); \
            explanation \(seconds(explained - asked)) s (\(reply.count) characters\(rambled ? ", RAN ON OR BROKE" : "")), first stop \(seconds(firstStop)) s after it
              - right: \(score.right.joined(separator: ", "))
              - wrong: \(score.wrong.joined(separator: ", "))
              - not in the boxes: \(score.unknown.joined(separator: ", "))
              - named but no stop: \(score.dropped.joined(separator: ", "))\(forbidden.isEmpty ? "" : "\n  - NAMED A WATERMARK: \(forbidden.joined(separator: ", "))")
            """
        return Line(text: summary, score: score)
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    private static func load(_ path: String, ignoreBelowY: Double?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard let cut = ignoreBelowY, cut < Double(image.height) else { return image }
        return image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Int(cut)))
    }

    private static func resized(_ image: CGImage, by scale: Double) -> CGImage? {
        let width = Int((Double(image.width) * scale).rounded()), height = Int((Double(image.height) * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The close-up with the parts' boxes (green) and the tour's stops (red, named).
    private static func render(_ closeUp: CGImage, entry: TourBenchmark.Image, scale: Double, stops: [Pointer]) -> CGImage? {
        let width = closeUp.width, height = closeUp.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(closeUp, in: CGRect(x: 0, y: 0, width: width, height: height))
        func flip(_ y: Double) -> Double { Double(height) - y }
        context.setStrokeColor(red: 0, green: 0.7, blue: 0.2, alpha: 0.9)
        context.setLineWidth(2)
        for part in entry.parts { for box in part.boxes where box.count == 4 {
            context.stroke(CGRect(x: box[0] * scale, y: flip(box[3] * scale), width: (box[2] - box[0]) * scale, height: (box[3] - box[1]) * scale))
        } }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 15, nil)
        for stop in stops {
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fillEllipse(in: CGRect(x: stop.x - 6, y: flip(stop.y) - 6, width: 12, height: 12))
            let label = NSAttributedString(string: stop.label, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            context.setFillColor(red: 0.85, green: 0, blue: 0, alpha: 1)
            context.textPosition = CGPoint(x: stop.x + 9, y: flip(stop.y) - 5)
            CTLineDraw(CTLineCreateWithAttributedString(label), context)
        }
        return context.makeImage()
    }

    private static func save(_ image: CGImage?, to url: URL) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
#endif
