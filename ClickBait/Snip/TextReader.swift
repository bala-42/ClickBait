import ClickBaitCore
import CoreGraphics
import Vision

/// Apple's on-device text recognition (Vision): the printed words in a snip's close-up
/// and where they are, so named parts can be placed by their written labels.
enum TextReader {
    /// Vision loads its text model the first time (seconds, once per boot); doing it at
    /// launch keeps that off the first snip.
    static func warmUp() {
        Task.detached(priority: .background) {
            guard let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let image = context.makeImage() else { return }
            _ = await read(image)
        }
    }

    /// `read`, but never keeping the answer waiting: nothing if it takes longer than `limit`.
    static func read(_ task: Task<[TextBox], Never>, within limit: Duration) async -> [TextBox] {
        await withTaskGroup(of: [TextBox]?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    static func read(_ image: CGImage) async -> [TextBox] {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false  // anatomy, code, product names
            let handler = VNImageRequestHandler(cgImage: image)
            do { try handler.perform([request]) } catch { return [] }
            let width = Double(image.width), height = Double(image.height)
            return (request.results ?? []).compactMap { observation -> TextBox? in
                guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                      !text.isEmpty else { return nil }
                // Vision's boxes are normalised with the origin at the bottom-left.
                let box = observation.boundingBox
                return TextBox(text: text, center: Point(x: box.midX * width, y: (1 - box.midY) * height))
            }
        }.value
    }
}
