#if canImport(CoreGraphics) && canImport(CoreText) && canImport(ImageIO)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClickBaitCore

/// Talks to a real local Ollama. Off by default; run with
/// `CLICKBAIT_LIVE_OLLAMA=1 swift test --package-path ClickBaitCore --filter LiveOllama`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_OLLAMA"] != nil))
struct LiveOllamaTests {
    @Test func answersAboutASyntheticScreenshot() async throws {
        let model = ProcessInfo.processInfo.environment["CLICKBAIT_OLLAMA_MODEL"] ?? OllamaProvider.defaultModel
        let provider = OllamaProvider(model: model)
        try await provider.checkConnection()

        let longEdge = Int(ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_LONG_EDGE"] ?? "") ?? 1280
        let snip = ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_SNIP"].flatMap(SnipKind.init(rawValue:))
        let (jpeg, width, height) = try SyntheticScreen.render(longEdge: longEdge, snipped: snip != nil)
        var request = AskRequest(
            question: ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_QUESTION"] ?? "How do I share this document?",
            screenshotJPEG: jpeg, screenshotWidth: width, screenshotHeight: height,
            context: ScreenContext(appName: "Notes"),
            // CLICKBAIT_LIVE_SNIP=circled|boxed tries the hold-⌥⌘ prompt on the same image.
            snip: snip,
            // CLICKBAIT_LIVE_ELEMENTS=1 offers an accessibility-style element list.
            elements: ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_ELEMENTS"] == nil ? [] : SyntheticScreen.elements(scale: Double(width) / 1280),
            // CLICKBAIT_LIVE_LOCATE=Share tries the zoomed-in second look.
            locate: ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_LOCATE"]
        )
        if ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_ORDER"] != nil {
            // The text-only "which action is this?" step.
            request.interpretOrder = true
            request.screenshotJPEG = Data()
            request.context = ScreenContext(appName: "Finder")
        }
        if let path = ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_IMAGE"] {
            // An image file as the snip close-up, scaled to 1280 on its long edge like the app.
            let (jpeg, w, h) = try SyntheticScreen.file(path)
            request.screenshotJPEG = jpeg
            request.screenshotWidth = w
            request.screenshotHeight = h
            request.snip = .circled
            print("LIVE size \(w)x\(h)")
        }
        if ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_TUTORIAL"] != nil {
            request.planTutorial = true  // the tutorial planner (with the element list if CLICKBAIT_LIVE_ELEMENTS)
        }
        if let app = ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_APP"] { request.context.appName = app }
        if let menus = ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_MENUS"] {
            request.menuOutline = menus.components(separatedBy: "|")  // "History ▸ Clear History…|…"
        }
        if let explanation = ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_PARTS"] {
            // The background "list the parts" look.
            request.listParts = true
            request.question = explanation
        }
        if ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_DIAGRAM"] != nil {
            // A labelled diagram as the close-up (see SyntheticScreen.diagram for positions).
            let (jpeg, w, h) = try SyntheticScreen.diagram(labelled: ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_UNLABELLED"] == nil)
            request.screenshotJPEG = jpeg
            request.screenshotWidth = w
            request.screenshotHeight = h
            request.snip = .circled
        }
        if snip != nil, ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_NO_CONTEXT"] == nil {
            // The small whole-screen context picture the app sends after the close-up.
            request.contextJPEG = try SyntheticScreen.render(longEdge: 768).0
        }
        if let earlier = ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_HISTORY"] {
            // A follow-up: the first exchange, then this question.
            request.history = [ChatTurn(role: .user, content: "The user circled something. Explain what they marked."),
                               .assistant(speech: earlier)]
        }
        let clock = ContinuousClock()
        let start = clock.now
        var firstChunk: Duration?
        var text = ""
        for try await chunk in provider.stream(request) {
            if firstChunk == nil { firstChunk = clock.now - start }
            text += chunk
        }
        print("LIVE \(width)x\(height) first chunk after \(firstChunk.map(String.init(describing:)) ?? "-"), total \(clock.now - start)")
        print("LIVE reply: \(text)")
        #expect(!text.isEmpty)
    }
}

/// A plain window with a blue "Share" button whose center is (1160, 60) at 1280×800,
/// scaled to `longEdge`. A random note defeats Ollama's prompt cache between runs.
enum SyntheticScreen {
    /// `snipped`: like a hold-⌥⌘ snip — the agenda line boxed in red, cropped around it.
    static func render(longEdge: Int = 1280, snipped: Bool = false) throws -> (Data, Int, Int) {
        let scale = CGFloat(longEdge) / 1280
        let width = longEdge, height = Int((800 * scale).rounded())
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // CoreGraphics' origin is bottom-left; flip so we can think in screenshot pixels.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)

        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        context.setFillColor(CGColor(gray: 0.88, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 100))

        draw("Meeting notes", at: CGPoint(x: 40, y: 160), size: 36, color: CGColor(gray: 0.1, alpha: 1), in: context)
        draw("Ticket #\(Int.random(in: 10_000...99_999)) — agenda: budget, hiring, launch date.", at: CGPoint(x: 40, y: 220), size: 22, color: CGColor(gray: 0.3, alpha: 1), in: context)

        context.setFillColor(CGColor(red: 0.0, green: 0.45, blue: 0.95, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 1100, y: 40, width: 120, height: 40), cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        draw("Share", at: CGPoint(x: 1130, y: 69), size: 20, color: CGColor(gray: 1, alpha: 1), in: context)

        var image = try #require(context.makeImage())
        if snipped {
            // Like the app: a clean close-up, no outline.
            let marked = try #require(context.makeImage())
            image = try #require(marked.cropping(to: CGRect(x: 0, y: 120 * scale, width: 900 * scale, height: 180 * scale).integral))
        }
        let (outWidth, outHeight) = (image.width, image.height)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return (data as Data, outWidth, outHeight)
    }

    /// What Accessibility might report for the synthetic window (plus a menu that isn't
    /// drawn, to see whether the model picks by name).
    static func elements(scale: Double) -> [PromptElement] {
        let raw: [(String, String, Double, Double)] = [
            ("menu", "Apple", 20, 12), ("menu", "Notes", 70, 12), ("menu", "File", 120, 12), ("menu", "Edit", 160, 12),
            ("menu", "View", 200, 12), ("button", "Close", 20, 60), ("button", "Minimize", 40, 60), ("button", "Zoom", 60, 60),
            ("button", "Sidebar", 110, 60), ("button", "New Note", 300, 60), ("text field", "Search", 900, 60),
            ("button", "Share", 1160, 60), ("menu item", "Show Path Bar", 230, 140), ("menu item", "Show Status Bar", 230, 162),
        ]
        return raw.enumerated().map { index, item in
            PromptElement(id: index + 1, kind: item.0, label: item.1, x: (item.2 * scale).rounded(), y: (item.3 * scale).rounded())
        }
    }

    /// A simple "rotator cuff" figure, 900×600: four coloured muscles around a grey
    /// humeral head, each with a written label (unless `labelled` is false). Centers:
    /// Supraspinatus (450, 140), Infraspinatus (690, 300), Teres minor (620, 470),
    /// Subscapularis (220, 330).
    static func diagram(labelled: Bool) throws -> (Data, Int, Int) {
        let width = 900, height = 600
        // Drawn at 900×600, sent at 1280 wide like the app's close-ups (×1.4222).
        let outWidth = 1280, outHeight = 853
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 0.98, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw("Rotator cuff (posterior and anterior view)", at: CGPoint(x: 230, y: 40), size: 24, color: CGColor(gray: 0.15, alpha: 1), in: context)
        context.setFillColor(CGColor(gray: 0.75, alpha: 1))
        context.fillEllipse(in: CGRect(x: 380, y: 240, width: 160, height: 160))  // humeral head
        let muscles: [(String, CGRect, CGColor)] = [
            ("Supraspinatus", CGRect(x: 330, y: 100, width: 240, height: 80), CGColor(red: 0.85, green: 0.35, blue: 0.35, alpha: 1)),
            ("Infraspinatus", CGRect(x: 600, y: 230, width: 180, height: 140), CGColor(red: 0.80, green: 0.45, blue: 0.30, alpha: 1)),
            ("Teres minor", CGRect(x: 550, y: 430, width: 140, height: 80), CGColor(red: 0.75, green: 0.30, blue: 0.45, alpha: 1)),
            ("Subscapularis", CGRect(x: 120, y: 260, width: 200, height: 140), CGColor(red: 0.70, green: 0.40, blue: 0.40, alpha: 1)),
        ]
        for (name, rect, color) in muscles {
            context.setFillColor(color)
            context.fillEllipse(in: rect)
            if labelled {
                draw(name, at: CGPoint(x: rect.minX + 10, y: rect.midY + 6), size: 18, color: CGColor(gray: 1, alpha: 1), in: context)
            }
        }
        let drawn = try #require(context.makeImage())
        let scaled = try #require(CGContext(
            data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        scaled.interpolationQuality = .high
        scaled.draw(drawn, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        let image = try #require(scaled.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return (data as Data, outWidth, outHeight)
    }

    static func file(_ path: String) throws -> (Data, Int, Int) {
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let original = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let factor = 1280 / Double(max(original.width, original.height))
        let width = Int((Double(original.width) * factor).rounded()), height = Int((Double(original.height) * factor).rounded())
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return (data as Data, width, height)
    }

    /// `baseline` is in flipped (top-left) coordinates.
    private static func draw(_ text: String, at baseline: CGPoint, size: CGFloat, color: CGColor, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
        context.saveGState()
        // Text draws upside down in a flipped context; flip it back locally.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = baseline
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
#endif
