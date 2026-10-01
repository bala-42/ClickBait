import Testing
@testable import ClickBaitCore

struct ScreenGeometryTests {
    /// 14" MacBook Pro: 1512×982 points, captured at 2× (3024×1964 px), sent at 1280×831.
    private let laptop = ScreenGeometry(
        imageWidth: 1280, imageHeight: 831,
        displayFrame: Rect(x: 0, y: 0, width: 1512, height: 982),
        primaryDisplayHeight: 982
    )

    private func expectClose(_ actual: Point, _ expected: Point, tolerance: Double = 0.01,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(actual.x - expected.x) <= tolerance && abs(actual.y - expected.y) <= tolerance,
                "\(actual) != \(expected)", sourceLocation: sourceLocation)
    }

    @Test func retinaPrimaryDisplay() {
        // Top-left corner pixel → top-left of the screen.
        expectClose(laptop.quartzPoint(fromImagePixel: Point(x: 0, y: 0)), Point(x: 0, y: 0))
        expectClose(laptop.appKitPoint(fromImagePixel: Point(x: 0, y: 0)), Point(x: 0, y: 982))
        // Center pixel → center of the screen.
        expectClose(laptop.quartzPoint(fromImagePixel: Point(x: 640, y: 415.5)), Point(x: 756, y: 491))
        expectClose(laptop.appKitPoint(fromImagePixel: Point(x: 640, y: 415.5)), Point(x: 756, y: 491))
        // The real Share reply from step 5: (1262, 50) px.
        expectClose(laptop.quartzPoint(fromImagePixel: Point(x: 1262, y: 50)), Point(x: 1490.74, y: 59.08))
    }

    @Test func nonRetinaDisplayWithoutDownscale() {
        let display = ScreenGeometry(
            imageWidth: 1280, imageHeight: 800,
            displayFrame: Rect(x: 0, y: 0, width: 1280, height: 800),
            primaryDisplayHeight: 800
        )
        expectClose(display.quartzPoint(fromImagePixel: Point(x: 100, y: 50)), Point(x: 100, y: 50))
        expectClose(display.appKitPoint(fromImagePixel: Point(x: 100, y: 50)), Point(x: 100, y: 750))
    }

    @Test func externalDisplayToTheLeft() {
        // 2560×1440 external display left of the laptop; AppKit x is negative.
        let external = ScreenGeometry(
            imageWidth: 1280, imageHeight: 720,
            displayFrame: Rect(x: -2560, y: 0, width: 2560, height: 1440),
            primaryDisplayHeight: 982
        )
        expectClose(external.appKitPoint(fromImagePixel: Point(x: 0, y: 0)), Point(x: -2560, y: 1440))
        // Its top edge is 458 pt above the laptop's top edge, so Quartz y is negative.
        expectClose(external.quartzPoint(fromImagePixel: Point(x: 0, y: 0)), Point(x: -2560, y: -458))
        expectClose(external.quartzPoint(fromImagePixel: Point(x: 640, y: 360)), Point(x: -1280, y: 262))
    }

    @Test func displayBelowThePrimary() {
        // 1920×1080 display placed under the laptop: AppKit y is negative.
        let below = ScreenGeometry(
            imageWidth: 1280, imageHeight: 720,
            displayFrame: Rect(x: 0, y: -1080, width: 1920, height: 1080),
            primaryDisplayHeight: 982
        )
        expectClose(below.appKitPoint(fromImagePixel: Point(x: 0, y: 0)), Point(x: 0, y: 0))
        expectClose(below.quartzPoint(fromImagePixel: Point(x: 0, y: 0)), Point(x: 0, y: 982))
        expectClose(below.quartzPoint(fromImagePixel: Point(x: 1280, y: 720)), Point(x: 1920, y: 2062))
    }

    @Test func pointsAreKeptOnTheDisplay() {
        expectClose(laptop.quartzPoint(fromImagePixel: Point(x: 2000, y: -50)), Point(x: 1512, y: 0))
    }

    @Test func quartzAndAppKitConvertBothWays() {
        let appKit = Point(x: 300, y: 700)
        let quartz = laptop.quartzPoint(fromAppKit: appKit)
        expectClose(quartz, Point(x: 300, y: 282))
        expectClose(laptop.appKitPoint(fromQuartz: quartz), appKit)
    }

    @Test(arguments: [Point(x: 0, y: 0), Point(x: 1262, y: 50), Point(x: 640.5, y: 415.25), Point(x: 1279, y: 719)])
    func imagePixelRoundTrips(_ pixel: Point) {
        for geometry in [laptop, ScreenGeometry(imageWidth: 1280, imageHeight: 720,
                                                displayFrame: Rect(x: -2560, y: 0, width: 2560, height: 1440),
                                                primaryDisplayHeight: 982)] {
            expectClose(geometry.imagePixel(fromQuartz: geometry.quartzPoint(fromImagePixel: pixel)), pixel)
        }
    }
}
