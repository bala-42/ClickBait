#if DEBUG
import AppKit
import ClickBaitCore

/// The screen-answer speed benchmark (docs/features/ask-and-answers.md, "Speed"): one capture
/// of the screen under the cursor, kept in memory only (never written), sent at each long edge
/// in `CLICKBAIT_ASK_BENCH`. For each size, `CLICKBAIT_ASK_RUNS` times: a general question
/// (time to the whole answer), and "where is …?" for up to six named elements of the app in
/// front, with the element list as ClickBait sends it (a hit lands within 12 pt of the
/// element), and the menu bar's names read from the picture alone (legibility). Debug only; uses the local model
/// (`CLICKBAIT_ASK_MODEL` overrides Settings' main model, to compare models):
///
///     CLICKBAIT_ASK_BENCH=1280,1024,896 CLICKBAIT_ASK_BENCH_OUT=<folder> …/ClickBait.app/Contents/MacOS/ClickBait
///
/// Writes report-ask.md and quits. It runs before anything else starts, so a ClickBait already
/// running is left alone.
@MainActor
enum AskBench {
    static func runIfRequested(settings: AppSettings) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let sizes = environment["CLICKBAIT_ASK_BENCH"]?.split(separator: ",").compactMap({ Int($0) }),
              !sizes.isEmpty else { return false }
        let out = URL(fileURLWithPath: environment["CLICKBAIT_ASK_BENCH_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
        let runs = Int(environment["CLICKBAIT_ASK_RUNS"] ?? "") ?? 2
        Task {
            let lines: [String]
            do { lines = try await bench(sizes: sizes, runs: runs, settings: settings, model: environment["CLICKBAIT_ASK_MODEL"]) } catch { lines = ["Failed: \(error)"] }
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try? lines.joined(separator: "\n").write(to: out.appending(path: "report-ask.md"), atomically: true, encoding: .utf8)
            print(lines.joined(separator: "\n"))
            NSApp.terminate(nil)
        }
        return true
    }

    private static func bench(sizes: [Int], runs: Int, settings: AppSettings, model: String?) async throws -> [String] {
        let capture = try await ScreenCapturer().captureDisplayUnderCursor(excluding: settings.blocklist)
        let front = NSWorkspace.shared.frontmostApplication
        let elements = await AskCoordinator.elements(in: capture, frontmostPID: front?.processIdentifier)
        let targets = pickTargets(elements)
        // Small text: the front window's title (13 pt), as Accessibility has it.
        let title = AXInspector.snapshot(frontmostPID: front?.processIdentifier).windowTitle ?? ""
        let titleWords = Set(title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 3 }.map(String.init))
        let menus = elements.filter { $0.role == "AXMenuBarItem" && $0.label != "Apple" }.map(\.label)
        let context = ScreenContext(appName: front?.localizedName)
        let provider = model.map { OllamaProvider(model: $0, fastModel: "") } ?? settings.makeProvider()
        await provider.warmUp()  // load time isn't answer time
        var lines = ["# Screen-answer benchmark, \(Date.now.formatted(date: .abbreviated, time: .shortened))", "",
                     "\(provider.model); capture \(capture.image.width)×\(capture.image.height); \(targets.count) targets in \(front?.localizedName ?? "?"), \(runs) runs each", "",
                     "| long edge | image | JPEG | general answer (median) | menu names read | window title read | where-is with list (median) | hits |", "|---|---|---|---|---|---|---|---|"]
        var misses: [String] = []
        for size in sizes {
            let encoded = try ScreenshotEncoder.encode(capture.image, longEdge: size)
            let geometry = capture.geometry(imageWidth: encoded.width, imageHeight: encoded.height)
            func ask(_ question: String, elements listed: [PromptElement] = []) async throws -> (reply: String, seconds: Double) {
                let request = AskRequest(question: question, screenshotJPEG: encoded.jpeg, screenshotWidth: encoded.width,
                                         screenshotHeight: encoded.height, context: context, elements: listed)
                let start = ContinuousClock.now
                var reply = ""
                for try await chunk in provider.stream(request) { reply += chunk }
                let elapsed = ContinuousClock.now - start
                return (reply, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            }
            var general: [Double] = [], locate: [Double] = [], hits = 0, tries = 0, read = 0, readable = 0, titles = 0
            for _ in 0..<runs {
                general.append(try await ask("What is on my screen right now? One sentence.").seconds)
                // Legibility: the menu names, read from the picture alone.
                let reading = try await ask("Read out every menu name in the menu bar at the top of the screen, left to right, separated by commas.").reply.lowercased()
                read += menus.filter { reading.contains($0.lowercased()) }.count
                misses.append("\(size) menu reading: \(reading.prefix(200).replacingOccurrences(of: "\n", with: " "))")
                readable += menus.count
                let titleReply = try await ask("What is the exact title of the front window? Reply with just the title.").reply.lowercased()
                if !titleWords.isEmpty, Double(titleWords.filter { titleReply.contains($0) }.count) >= 0.8 * Double(titleWords.count) { titles += 1 }
                for target in targets {
                    // As ClickBait asks "where" questions: with the element list.
                    let question = "Where is the “\(target.label)” \(target.kind)? Point at it."
                    let listed = PromptElement.list(elements, geometry: geometry, question: question, limit: AskCoordinator.maxListedElements)
                    let (reply, seconds) = try await ask(question, elements: listed)
                    locate.append(seconds)
                    tries += 1
                    let parsed = ResponseParser.parse(reply, imageWidth: encoded.width, imageHeight: encoded.height,
                                                      elements: listed, scale: provider.coordinateScale)
                    let pointer = parsed.response.pointers.first
                    let point = pointer.map { geometry.quartzPoint(fromImagePixel: Point(x: $0.x, y: $0.y)) }
                    misses.append("\(size) “\(target.label)” at \(Int(target.frame.x)),\(Int(target.frame.y)): \(point.map { "\(Int($0.x)),\(Int($0.y))" } ?? "none") ← \(reply.prefix(160).replacingOccurrences(of: "\n", with: " "))")
                    guard let point else { continue }
                    let frame = target.frame
                    if point.x >= frame.x - 12, point.x <= frame.x + frame.width + 12,
                       point.y >= frame.y - 12, point.y <= frame.y + frame.height + 12 { hits += 1 }
                }
            }
            lines.append("| \(size) | \(encoded.width)×\(encoded.height) | \(encoded.jpeg.count / 1024) KB | \(median(general)) s | \(read)/\(readable) | \(titles)/\(runs) | \(median(locate)) s | \(hits)/\(tries) |")
        }
        lines += ["", "Window title: “\(title)”"] + misses.map { "- " + $0 }
        lines += ["", "Targets: " + targets.map { "“\($0.label)” (\($0.kind), \(Int($0.frame.width))×\(Int($0.frame.height)) pt)" }.joined(separator: ", ")]
        return lines
    }

    /// Up to six named, uniquely labelled elements big enough to see, spread through the list.
    private static func pickTargets(_ elements: [ScreenElement]) -> [ScreenElement] {
        var counts: [String: Int] = [:]
        for element in elements { counts[element.label, default: 0] += 1 }
        let named = elements.filter {
            (3...30).contains($0.label.count) && counts[$0.label] == 1 && $0.frame.width >= 8 && $0.frame.height >= 8
        }
        guard named.count > 6 else { return named }
        let step = Double(named.count) / 6
        return (0..<6).map { named[Int(Double($0) * step)] }
    }

    private static func median(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "–" }
        let sorted = values.sorted()
        return String(format: "%.1f", sorted[sorted.count / 2])
    }
}
#endif
