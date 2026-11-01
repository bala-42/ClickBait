import AppKit
import OSLog
import Vision

/// "A picture where I'm holding a dog" (user's ask, 2026-11-01): the user picks one photo of
/// themselves in Settings; each picture's faces are compared with it, and matches are tagged
/// as the user (`SmartSearch.Item.hasYou`). Apple has no public face recognition, so this
/// compares Vision's image feature prints of the face crops: good at "same person, similar
/// look", not Face ID. The reference stays in `you-face.print`; nothing leaves the Mac.
enum YourFace {
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ClickBait/you-face.print")
    }

    /// Feature-print distance under which two faces count as the same person. Measured
    /// 2026-11-01 on 26 faces from this Mac: unrelated faces were never under 0.75 (4% under
    /// 0.8); faces from the same folder (often the same person) were under 0.75 about a
    /// quarter of the time. Cautious: few wrong tags, many photos of the user missed.
    static let threshold: Float = 0.75

    static var isSet: Bool { FileManager.default.fileExists(atPath: file.path) }

    static func reference() -> VNFeaturePrintObservation? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    /// Saves the biggest face in `url` as the reference; false when there's no face.
    static func setReference(from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([faces])
        guard let face = (faces.results ?? []).max(by: { area($0) < area($1) }),
              let print = featurePrint(of: face, in: image),
              let data = try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    static func clear() {
        try? FileManager.default.removeItem(at: file)
    }

    static func matches(_ reference: VNFeaturePrintObservation, face: VNFaceObservation, in image: CGImage) -> Bool {
        // Tiny faces in a crowd are too blurry to compare.
        guard face.boundingBox.width * CGFloat(image.width) >= 48, let print = featurePrint(of: face, in: image) else { return false }
        var distance: Float = .infinity
        try? reference.computeDistance(&distance, to: print)
        return distance < threshold
    }

    /// The face with a margin (hair, jaw), squared, as Vision's feature print.
    private static func featurePrint(of face: VNFaceObservation, in image: CGImage) -> VNFeaturePrintObservation? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let box = face.boundingBox
        let side = max(box.width * width, box.height * height) * 1.4
        let rect = CGRect(x: box.midX * width - side / 2, y: (1 - box.midY) * height - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isEmpty, let crop = image.cropping(to: rect) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: crop).perform([request])
        return request.results?.first
    }

    private static func area(_ face: VNFaceObservation) -> CGFloat { face.boundingBox.width * face.boundingBox.height }
}
