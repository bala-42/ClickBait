import ClickBaitCore
import CoreGraphics

/// Finds a word on screen by reading it (Vision, on device): menu titles and items when an app
/// won't describe its menu bar to Accessibility (Safari after days running).
enum ScreenText {
    /// Where `label` is written inside `region` (Quartz points) of `capture`, as a small box
    /// around it; nil when it isn't there. "…" and case don't matter.
    static func find(_ label: String, in region: Rect, of capture: ScreenCapture) async -> Rect? {
        let geometry = capture.geometry(imageWidth: capture.image.width, imageHeight: capture.image.height)
        let topLeft = geometry.imagePixel(fromQuartz: Point(x: region.minX, y: region.minY))
        let bottomRight = geometry.imagePixel(fromQuartz: Point(x: region.maxX, y: region.maxY))
        let crop = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            .intersection(CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height))
        guard !crop.isEmpty, let image = capture.image.cropping(to: crop) else { return nil }
        let name = { (text: String) in ImpliedPointer.normalized(TutorialPlan.withoutEllipsis(text)) }
        let wanted = name(label)
        // The top-most match: the menu bar's title before the same word in a page below it.
        guard !wanted.isEmpty,
              let box = await TextReader.read(image).filter({ name($0.text) == wanted }).min(by: { $0.center.y < $1.center.y })
        else { return nil }
        let center = geometry.quartzPoint(fromImagePixel: Point(x: box.center.x + crop.minX, y: box.center.y + crop.minY))
        let width = max(30, Double(label.count) * 8)
        return Rect(x: center.x - width / 2, y: center.y - 11, width: width, height: 22)
    }
}
