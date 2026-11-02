import AppKit
import AVFoundation
import ClickBaitCore
import SwiftUI

// MARK: - Volume HUD

/// The volume keys' HUD as a Pac-Man level (user's design, 2026-10-23): on arcade blue, the
/// speaker in the left wing and the percentage in the right, in the arcade font; under the
/// notch a corridor of 20 pellets as wide as the HUD. Pac-Man stands at the level: turning it
/// up he chomps right and the pellets behind him turn green, turning it down he backs up and
/// they turn red again. Muted, he greys out and every pellet is red. Reduce Motion: he jumps.
struct HUDWings: View {
    let level: Double
    let muted: Bool
    @State private var from = 0.0
    @State private var to = 0.0
    @State private var start = Date.distantPast
    @State private var facingLeft = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let pellets = 20
    /// One move's length, s.
    private static let travel = 0.32

    var body: some View {
        // Layered, not stacked: the corridor pinned to the bottom edge can never be pushed out.
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                Image(systemName: muted ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: NotchPanel.hudWing)
                // The top middle: the four ghosts, each doing its own thing.
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
                    GhostParade(time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate, frightened: muted)
                }
                .frame(maxWidth: .infinity)
                Text(muted ? "MUTE" : "\(Int((level * 100).rounded()))%")
                    .font(ArcadeFont.font(11))
                    .foregroundStyle(muted ? PacMan.red : .white)
                    .frame(width: NotchPanel.hudWing)
            }
            .frame(maxHeight: .infinity)
            .padding(.bottom, NotchPanel.hudCorridor)
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                corridor(at: context.date)
            }
            .frame(height: NotchPanel.hudCorridor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PacMan.navy)
        .onAppear { (from, to) = (level, level) }
        .onChange(of: level) { old, new in
            from = position(at: .now)
            to = new
            start = reduceMotion ? .distantPast : .now
            facingLeft = new < old
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(muted ? "Volume muted" : "Volume \(Int((level * 100).rounded())) percent")
    }

    /// Where Pac-Man is (0…1), easing from `from` to `to`.
    private func position(at date: Date) -> Double {
        let t = min(1, max(0, date.timeIntervalSince(start) / Self.travel))
        let eased = 1 - (1 - t) * (1 - t)
        return from + (to - from) * eased
    }

    private func corridor(at date: Date) -> some View {
        let at = muted ? 0 : position(at: date)
        let moving = date.timeIntervalSince(start) < Self.travel
        // The mouth: chomping while he moves, a resting bite when he stops.
        let mouth = moving ? 0.05 + 0.6 * abs(sin(date.timeIntervalSinceReferenceDate * 22)) : 0.45
        return GeometryReader { proxy in
            let inset: CGFloat = 16
            let span = proxy.size.width - 2 * inset
            let mid = proxy.size.height / 2
            ZStack(alignment: .topLeading) {
                // The maze walls above and below the corridor: hard pixel lines.
                ForEach([3.0, proxy.size.height - 3], id: \.self) { y in
                    Rectangle().fill(PacMan.wall)
                        .frame(width: proxy.size.width - 16, height: 2)
                        .position(x: proxy.size.width / 2, y: y)
                }
                ForEach(0..<Self.pellets, id: \.self) { index in
                    let x = (Double(index) + 0.5) / Double(Self.pellets)
                    if x > at + 0.012 || x < at - 0.035 {  // under Pac-Man's mouth: gone from view
                        Rectangle()  // a pellet is a square of pixels
                            .fill(x < at ? PacMan.green : PacMan.red)
                            .frame(width: 3, height: 3)
                            .position(x: (inset + span * x).rounded(), y: mid.rounded())
                    }
                }
                PixelPacMan(mouth: mouth, color: muted ? Color(white: 0.5) : PacMan.yellow)
                    .scaleEffect(x: facingLeft ? -1 : 1)
                    .position(x: inset + span * at, y: mid)
            }
        }
    }
}

/// The brightness HUD (user's idea, 2026-10-24): a CRT-like pixel sky that travels through
/// the day with the level, night at 0 to noon at 1. Stars fade out, the moon sets, the sun
/// rises along the strip under the notch (never behind it), clouds drift in. 1 pt pixels, finer
/// than Pac-Man's (asked for); scanlines and a dark rim for the tube.
struct SkyWings: View {
    let level: Double
    @State private var from: Double
    @State private var to: Double
    @State private var start = Date.distantPast

    /// Starts at the level: its first frame is already the right time of day.
    init(level: Double) {
        self.level = level
        _from = State(initialValue: level)
        _to = State(initialValue: level)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let travel = 0.45

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion && Date().timeIntervalSince(start) > Self.travel)) { context in
                let at = position(at: context.date)
                Canvas { canvas, size in
                    SkyPainter(level: at, time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate, size: size)
                        .paint(&canvas)
                }
            }
            HStack(spacing: 0) {
                Image(systemName: level < 0.35 ? "moon.stars.fill" : level < 0.55 ? "sunrise.fill" : "sun.max.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                    .frame(width: NotchPanel.hudWing)
                Spacer(minLength: 0)
                Text("\(Int((level * 100).rounded()))%")
                    .font(ArcadeFont.font(11))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 0, x: 1, y: 1)
                    .frame(width: NotchPanel.hudWing)
            }
            .frame(maxHeight: .infinity)
            .padding(.bottom, NotchPanel.hudCorridor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: level) { _, new in
            from = position(at: .now)
            to = new
            start = reduceMotion ? .distantPast : .now
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Brightness \(Int((level * 100).rounded())) percent")
    }

    private func position(at date: Date) -> Double {
        let t = min(1, max(0, date.timeIntervalSince(start) / Self.travel))
        return from + (to - from) * (1 - (1 - t) * (1 - t))
    }
}

/// Draws one frame of the sky: banded gradient, stars, moon or sun, clouds, hills, scanlines.
private struct SkyPainter {
    let level: Double
    let time: TimeInterval
    let size: CGSize
    /// One sky pixel, pt: two screen pixels on Retina.
    static let pixel: CGFloat = 1

    /// (top, middle, bottom) of the sky at night, before dawn, sunrise, morning and noon.
    static let keys: [(Double, [UInt32])] = [
        (0.0, [0x05071A, 0x0B1033, 0x141B48]),
        (0.25, [0x120F38, 0x2A1E5C, 0x5A3577]),
        (0.5, [0x2B3A8C, 0xC4609A, 0xF59A5B]),
        (0.75, [0x2E7BD6, 0x6FB2EE, 0xB8E2F7]),
        (1.0, [0x1E7BFF, 0x5FB4FF, 0xA9E3FF]),
    ]

    func paint(_ context: inout GraphicsContext) {
        let width = size.width, height = size.height
        let stops = Self.stops(at: level)
        // The sky in 2 pt bands, each band's lower row dithered toward the next: a pixel gradient.
        var y: CGFloat = 0
        while y < height {
            let t = Double(y / height)
            context.fill(Path(CGRect(x: 0, y: y, width: width, height: 2)), with: .color(Self.sky(stops, t)))
            y += 2
        }
        // Stars, fading out by dawn; each twinkles on its own beat.
        let night = max(0, 1 - level / 0.35)
        if night > 0 {
            var seed: UInt64 = 7
            for index in 0..<46 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let x = CGFloat((seed >> 33) % 10_000) / 10_000 * width
                let sy = CGFloat((seed >> 17) % 1_000) / 1_000 * (height - 12)
                let twinkle = 0.55 + 0.45 * sin(time * (1.3 + Double(index % 5) * 0.4) + Double(index))
                context.fill(Path(CGRect(x: x.rounded(), y: sy.rounded(), width: Self.pixel, height: Self.pixel)),
                             with: .color(.white.opacity(night * twinkle)))
            }
        }
        // The moon, then the sun, travelling along the strip under the notch with the level.
        let x = (16 + (width - 32) * level).rounded()
        let bodyY = (height - 9 - 8 * level).rounded()
        let moon = 1 - Self.smooth(0.28, 0.42, level)
        if moon > 0 { disc(&context, x: x, y: bodyY, radius: 5, color: Color(hex: 0xF4F1D0).opacity(moon), bite: 2.5) }
        let sun = Self.smooth(0.36, 0.5, level)
        if sun > 0 {
            let warm = Self.smooth(0.4, 0.9, level)
            disc(&context, x: x, y: bodyY, radius: 8, color: Color(hex: 0xFFD27A).opacity(0.28 * sun), bite: 0)  // its glow
            disc(&context, x: x, y: bodyY, radius: 5.5, color: Self.mix(0xFF7A3D, 0xFFE680, warm).opacity(sun), bite: 0)
        }
        // Clouds drifting in by morning, pink at sunrise.
        let cloudy = Self.smooth(0.3, 0.7, level)
        if cloudy > 0 {
            let sunrise = max(0, 1 - abs(level - 0.5) / 0.2)
            let tint = Self.mix(0xFFFFFF, 0xFFB7CF, sunrise).opacity(0.92 * cloudy)
            for (index, cloud) in [(0.08, 6.0), (0.37, 3.0), (0.62, 9.0), (0.88, 5.0)].enumerated() {
                let drift = (time * (3 + Double(index))).truncatingRemainder(dividingBy: Double(width) + 40)
                let cx = ((cloud.0 * Double(width) + drift).truncatingRemainder(dividingBy: Double(width) + 40)) - 20
                for (row, line) in Self.cloud.enumerated() {
                    for (column, filled) in line.enumerated() where filled == "#" {
                        context.fill(Path(CGRect(x: CGFloat(cx).rounded() + CGFloat(column) * Self.pixel,
                                                 y: CGFloat(cloud.1) + CGFloat(row) * Self.pixel, width: Self.pixel, height: Self.pixel)),
                                     with: .color(tint))
                    }
                }
            }
        }
        // Hills along the bottom: dark at night, green by day.
        var hills = Path()
        var column: CGFloat = 0
        while column < width {
            let rise = (3 + 1.6 * sin(Double(column) / 23) + 1.1 * sin(Double(column) / 9)).rounded()
            hills.addRect(CGRect(x: column, y: height - CGFloat(rise), width: 1, height: CGFloat(rise)))
            column += 1
        }
        context.fill(hills, with: .color(Self.mix(0x060914, 0x2E7D4F, Self.smooth(0.3, 0.9, level))))
        // The tube: scanlines every other row, a darker rim.
        var lines = Path()
        var row: CGFloat = 1
        while row < height {
            lines.addRect(CGRect(x: 0, y: row, width: width, height: 1))
            row += 2
        }
        context.fill(lines, with: .color(.black.opacity(0.16)))
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.35)]),
                                           center: CGPoint(x: width / 2, y: height / 2), startRadius: height * 0.6, endRadius: width * 0.6))
    }

    /// A pixel disc; `bite` > 0 cuts a crescent from its upper right.
    private func disc(_ context: inout GraphicsContext, x: CGFloat, y: CGFloat, radius: Double, color: Color, bite: Double) {
        var shape = Path()
        let span = Int(radius.rounded(.up))
        for dy in -span...span {
            for dx in -span...span {
                let fx = Double(dx) + 0.5, fy = Double(dy) + 0.5
                guard fx * fx + fy * fy <= radius * radius else { continue }
                if bite > 0 {
                    let bx = fx - bite, by = fy + bite * 0.5
                    if bx * bx + by * by <= radius * radius * 0.8 { continue }
                }
                shape.addRect(CGRect(x: x + CGFloat(dx), y: y + CGFloat(dy), width: Self.pixel, height: Self.pixel))
            }
        }
        context.fill(shape, with: .color(color))
    }

    static let cloud = ["...####.....", ".########...", "############", ".##########."]

    private static func stops(at level: Double) -> [UInt32] {
        guard let upper = keys.firstIndex(where: { $0.0 >= level }), upper > 0 else { return keys[0].1 }
        let (a, b) = (keys[upper - 1], keys[upper])
        let t = (level - a.0) / (b.0 - a.0)
        return zip(a.1, b.1).map { blend($0, $1, t) }
    }

    /// Top → middle (60% down) → bottom.
    private static func sky(_ stops: [UInt32], _ t: Double) -> Color {
        let value = t < 0.6 ? blend(stops[0], stops[1], t / 0.6) : blend(stops[1], stops[2], (t - 0.6) / 0.4)
        return Color(hex: value)
    }

    private static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color { Color(hex: blend(a, b, t)) }

    private static func blend(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let t = min(1, max(0, t))
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    private static func smooth(_ low: Double, _ high: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }
}

/// The arcade's colours.
private enum PacMan {
    static let navy = Color(hex: 0x0B0B6B)
    static let wall = Color(hex: 0x2121DE)
    static let yellow = Color(hex: 0xFFE600)
    static let red = Color(hex: 0xFF3B3B)
    static let green = Color(hex: 0x3BE36B)
}

/// Pac-Man facing right as arcade pixels (user's ask, 2026-10-23): a 13 × 13 grid, each
/// pixel in the disc and outside the mouth's wedge filled, `mouth` 0 (shut) … 1 (wide).
private struct PixelPacMan: View {
    let mouth: Double
    let color: Color
    /// 1.5 pt: three whole screen pixels on a Retina display, so no seams between them.
    static let grid = 13, pixel: CGFloat = 1.5

    var body: some View {
        Canvas { context, _ in
            let r = Double(Self.grid) / 2, half = 40 * mouth * .pi / 180
            var shape = Path()
            for y in 0..<Self.grid {
                for x in 0..<Self.grid {
                    let dx = Double(x) + 0.5 - r, dy = Double(y) + 0.5 - r
                    guard dx * dx + dy * dy <= r * r - 0.6 else { continue }
                    if dx > 0, abs(atan2(dy, dx)) < half { continue }  // the mouth
                    shape.addRect(CGRect(x: CGFloat(x) * Self.pixel, y: CGFloat(y) * Self.pixel, width: Self.pixel, height: Self.pixel))
                }
            }
            context.fill(shape, with: .color(color))  // one fill: no seams
        }
        .frame(width: CGFloat(Self.grid) * Self.pixel, height: CGFloat(Self.grid) * Self.pixel)
    }
}

/// The four ghosts in the HUD's top middle (user's ask, 2026-10-23), each on its own beat:
/// bobbing, their skirts flicking between two frames, eyes glancing left and right, drifting
/// a little. Muted, they turn frightened blue. `time` 0 (Reduce Motion): they stand still.
private struct GhostParade: View {
    let time: TimeInterval
    let frightened: Bool
    static let colours = [0xFF0000, 0xFFB8FF, 0x00FFFF, 0xFFB852].map { Color(hex: UInt32($0)) }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { index in
                let t = time + Double(index) * 0.73
                PixelGhost(colour: frightened ? Color(hex: 0x2121FF) : Self.colours[index],
                           skirt: Int(t * 6) % 2, looksRight: sin(t * 0.9 + Double(index)) > 0, frightened: frightened)
                    .offset(x: (CGFloat(sin(t * 1.1)) * 2).rounded() * 1.5, y: sin(t * 4) > 0 ? 1.5 : 0)  // whole pixels, bobbing down
            }
        }
        .accessibilityHidden(true)
    }
}

/// One ghost from the arcade's 14 × 14 bitmap: dome, body, a two-frame skirt, white eyes
/// with blue pupils looking left or right (frightened: a wobbly mouth, no pupils).
private struct PixelGhost: View {
    let colour: Color
    let skirt: Int
    let looksRight: Bool
    let frightened: Bool
    static let pixel: CGFloat = 1.5

    static let body = [
        "     ####     ", "   ########   ", "  ##########  ", " ############ ", " ############ ", " ############ ",
        "##############", "##############", "##############", "##############", "##############", "##############",
    ]
    static let skirts = [["##.###..###.##", "#...##..##...#"], ["####.####.####", ".##..####..##."]]

    var body: some View {
        Canvas { context, _ in
            let p = Self.pixel
            // Each colour's pixels gathered into one path and filled once: no seams.
            var layers: [(Color, Path)] = []
            func layer(_ c: Color, _ points: [(Int, Int)]) {
                var path = Path()
                for (x, y) in points { path.addRect(CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: p)) }
                layers.append((c, path))
            }
            var bodyPoints: [(Int, Int)] = []
            for (y, row) in (Self.body + Self.skirts[skirt]).enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" { bodyPoints.append((x, y)) }
            }
            layer(colour, bodyPoints)
            if frightened {
                let face = [3, 4, 9, 10].map { ($0, 5) } + (2...11).enumerated().map { ($0.element, $0.offset % 2 == 0 ? 9 : 8) }
                layer(Color(hex: 0xFFB8AE), face)
            } else {
                var whites: [(Int, Int)] = [], pupils: [(Int, Int)] = []
                for left in [2, 8] {
                    for y in 3...7 {
                        for x in left...(left + 3) where !((y == 3 || y == 7) && (x == left || x == left + 3)) { whites.append((x, y)) }
                    }
                    let pupil = looksRight ? left + 2 : left
                    for y in 5...6 { for x in pupil...(pupil + 1) { pupils.append((x, y)) } }
                }
                layer(.white, whites)
                layer(Color(hex: 0x2121DE), pupils)
            }
            for (c, path) in layers { context.fill(path, with: .color(c)) }
        }
        .frame(width: 14 * Self.pixel, height: 14 * Self.pixel)
    }
}

/// Press Start 2P (SIL Open Font License 1.1, bundled with its licence): the volume HUD's
/// arcade lettering. Registered for this process on first use.
enum ArcadeFont {
    private static let registered: Bool = {
        guard let url = Bundle.main.url(forResource: "PressStart2P-Regular", withExtension: "ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func font(_ size: CGFloat) -> Font {
        _ = registered
        return .custom("PressStart2P-Regular", size: size)
    }
}
