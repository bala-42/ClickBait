import ClickBaitCore
import CoreGraphics
import Vision

/// Faces in a snipped image, on-device (Vision), so named people are pointed at real
/// faces (`FaceSnapping`) instead of where the model loosely put them.
enum FaceFinder {
    /// Face centres and widths in the image's pixels (origin top-left, like the parts).
    static func faces(in image: CGImage) -> [(center: Point, width: Double)] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Log.ask.error("Face detection failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let width = Double(image.width), height = Double(image.height)
        return (request.results ?? []).map { face in
            let box = face.boundingBox  // normalised, origin bottom-left
            return (Point(x: box.midX * width, y: (1 - box.midY) * height), box.width * width)
        }
    }
}
