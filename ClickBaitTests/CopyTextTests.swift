import AppKit
import CoreImage
import Testing
@testable import ClickBait

/// Copy text's reading: a QR code's contents first, else the text, on real pictures.
struct CopyTextTests {
    private func picture(_ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 600, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 200))
        draw(context)
        return try #require(context.makeImage())
    }

    @Test func readsText() async throws {
        let image = try picture { context in
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Invoice 2041 paid" as NSString).draw(at: CGPoint(x: 30, y: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        }
        let found = try #require(await ScreenWatcher.copyableText(in: image))
        #expect(!found.isCode && found.text.contains("Invoice 2041"))
    }

    @Test func readsAQRCode() async throws {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("https://clickbait.example/qr".utf8), forKey: "inputMessage")
        let code = try #require(filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)))
        let image = try #require(CIContext().createCGImage(code, from: code.extent))
        let found = try #require(await ScreenWatcher.copyableText(in: image))
        #expect(found.isCode && found.text == "https://clickbait.example/qr")
    }
}
