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
        let (jpeg, width, height) = try SyntheticScreen.render(longEdge: longEdge)
        let request = AskRequest(
            question: ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_QUESTION"] ?? "How do I share this document?",
            screenshotJPEG: jpeg, screenshotWidth: width, screenshotHeight: height,
            context: ScreenContext(appName: "Notes")
        )
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
    static func render(longEdge: Int = 1280) throws -> (Data, Int, Int) {
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

        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
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
