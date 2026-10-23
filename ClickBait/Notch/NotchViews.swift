import AppKit
import AVFoundation
import ClickBaitCore
import SwiftUI

/// One native drag session with several file URLs, suitable for dropping the selection
/// together onto Finder's AirDrop window.
private struct MultiFileDragHandle: NSViewRepresentable {
    let urls: [URL]

    func makeNSView(context: Context) -> MultiFileDragView { MultiFileDragView(urls: urls) }

    func updateNSView(_ view: MultiFileDragView, context: Context) { view.urls = urls }
}

private final class MultiFileDragView: NSView, NSDraggingSource {
    var urls: [URL]
    private var mouseDownPoint: NSPoint?

    init(urls: [URL]) {
        self.urls = urls
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint,
              hypot(event.locationInWindow.x - convert(start, to: nil).x,
                    event.locationInWindow.y - convert(start, to: nil).y) > 3,
              !urls.isEmpty else { return }
        mouseDownPoint = nil
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let offset = CGFloat(index) * 4
            let iconFrame = CGRect(x: bounds.midX - 18 + offset, y: bounds.midY - 18 - offset, width: 36, height: 36)
            item.setDraggingFrame(iconFrame, contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

// The notch panel: a black island that peeks with the bean, and opens on Home (the track or
// the keys, and the pills), Ask, Shelf and Settings.

/// The notch's outline: flush with the top, its upper corners flaring out into the menu bar
/// (`ear`), its lower corners rounded.
struct NotchShape: InsettableShape {
    var ear: CGFloat
    var bottom: CGFloat
    var inset: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func inset(by amount: CGFloat) -> NotchShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let e = min(ear, r.width / 4), b = min(bottom, r.height / 2, (r.width - 2 * e) / 2)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.minY + e), control: CGPoint(x: r.minX + e, y: r.minY))
        path.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - b))
        path.addQuadCurve(to: CGPoint(x: r.minX + e + b, y: r.maxY), control: CGPoint(x: r.minX + e, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX - e - b, y: r.maxY))
        path.addQuadCurve(to: CGPoint(x: r.maxX - e, y: r.maxY - b), control: CGPoint(x: r.maxX - e, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - e, y: r.minY))
        path.closeSubpath()
        return path
    }
}

struct NotchView: View {
    let model: NotchController.Model
    let notch: Rect?
    let music: MusicBridge
    let shelf: ShelfStore
    let settings: AppSettings
    let speech: SpeechModelManager
    let speaker: Speaker
    let searxng: SearXNGStatus
    let onDragIn: () -> Void
    let onTabChange: (NotchController.Model.Tab) -> Void
    let onCollapse: () -> Void

    @Namespace private var art

    /// Settings' way back, named after the tab it came from.
    private static func backLabel(_ tab: NotchController.Model.Tab) -> String {
        switch tab {
        case .shelf: "Back to Shelf"
        case .ask: "Back to Ask"
        case .home, .settings, .mirror, .music: "Back to Home"
        }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open = model.state == .expanded
        let look = NotchPanel.shape(model.state, notch: notch, activity: model.activity, hud: model.hud != nil,
                                    shelf: model.tab == .shelf, settings: model.tab == .settings, mirror: model.tab == .mirror,
                                    chat: model.showsChat)
        let ear = CGFloat(NotchPanel.ear)
        let shape = NotchShape(ear: ear, bottom: CGFloat(look.radius))
        // The open size for this tab, whatever the state: the open content is laid out at it
        // once and keeps it while it fades out, so closing fades instead of cutting off.
        let openLook = NotchPanel.shape(.expanded, notch: notch, activity: model.activity, hud: false,
                                        shelf: model.tab == .shelf, settings: model.tab == .settings, mirror: model.tab == .mirror,
                                        chat: model.showsChat)
        let openFrame = CGSize(width: CGFloat(openLook.width), height: CGFloat(openLook.height))
        let place = BeanPlace(state: model.state, tab: model.tab, mirror: model.tab == .mirror || model.showsChat, hud: model.hud != nil,
                              greeting: model.greeting, cover: music.hasTrack && music.artwork != nil, space: FocusCard.showsSpace(music),
                              width: CGFloat(look.width), height: CGFloat(look.height))
        // Folded with nothing to show: no black block, only a small see-through handle, as
        // HeyClicky's (user's choice, 2026-10-23). The black grows in from it as it opens.
        let resting = model.state == .collapsed && !model.activity && model.hud == nil
        ZStack(alignment: .top) {
            shape.fill(Color.black.opacity(resting ? 0 : 1))
            if resting {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 60, height: 5)
                    .padding(.top, 8)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            Group {
                if open {
                    if model.tab == .mirror {
                        PhotoBooth { onTabChange(.home) }
                            .frame(width: openFrame.width, height: openFrame.height, alignment: .top)
                            .transition(.opacity)
                    } else if model.tab == .settings {
                        SettingsView(settings: settings, speech: speech, speaker: speaker,
                                     searxng: searxng, menu: model.menuBar, health: model.health,
                                     permissions: model.permissions, startPage: model.settingsPage,
                                     returnLabel: Self.backLabel(model.settingsReturnTab),
                                     onBack: { onTabChange(model.settingsReturnTab) }, onCollapse: onCollapse)
                            .frame(width: openFrame.width, height: openFrame.height, alignment: .top)
                            .transition(.opacity)
                    } else {
                        OpenNotch(model: model, music: music, shelf: shelf, settings: settings,
                                  onTabChange: onTabChange, onMirror: { onTabChange(.mirror) }, onCollapse: onCollapse)
                            .frame(width: openFrame.width, height: openFrame.height, alignment: .top)
                            .transition(.opacity)
                    }
                } else if let hud = model.hud {
                    HUDWings(level: hud.level, muted: hud.muted)
                } else if model.state == .peek {
                    PeekContent(music: music)
                        .transition(.opacity)
                } else if model.activity {
                    ActivityWings(music: music, art: art)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, ear)
            .frame(width: CGFloat(look.width) + 2 * ear, height: CGFloat(look.height), alignment: .top)
        }
        // The open content is laid out once at its size (`openFrame`), not at every in-between
        // size of the spring (that relaid out the cards, stars and beans each frame: choppy).
        // The black shape springs around it as a mask, as the dock moves only transforms.
        .frame(width: CGFloat(look.width) + 2 * ear, height: CGFloat(look.height), alignment: .top)
        .clipShape(shape)
        // One bean, always there, so it springs from the peek into the open card and back.
        .overlay(alignment: .topLeading) {
            NotchBean(mood: model.greeting ? .hello : model.mood(), size: place.size, awake: open)
                .modifier(SpaceFloat(on: place.floats))
                .position(x: ear + place.x, y: place.y)
                .opacity(place.visible ? 1 : 0)
                .allowsHitTesting(place.visible)
        }
        .contentShape(shape)
        .dropDestination(for: URL.self) { _, _ in false } isTargeted: { if $0, !open { onDragIn() } }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : spring(open: open), value: open)
        .animation(reduceMotion ? nil : spring(open: model.state != .collapsed), value: model.state)
        .animation(reduceMotion ? nil : spring(open: true), value: model.tab)
        .animation(reduceMotion ? nil : spring(open: true), value: look.width)
        .animation(reduceMotion ? nil : spring(open: true), value: look.height)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: model.activity)
        .accessibilityElement(children: open ? .contain : .ignore)
        .accessibilityLabel(open ? "ClickBait notch" : model.activity ? "Now playing: \(music.title)" : "ClickBait notch, closed")
        .accessibilityHint(open ? "" : "Click to open")
        .accessibilityAddTraits(open ? [] : .isButton)
    }

    /// The motion: a lively spring opening (and for tab changes), a quick ease-out closing.
    private func spring(open: Bool) -> Animation {
        open ? Look.Motion.open : Look.Motion.close
    }
}

/// Where the bean sits, in the island's own points (top-left origin): small on the peek's
/// left, large on the home card's left (small on the cover's corner while a track has one),
/// smaller beside the ask field; gone elsewhere.
private struct BeanPlace {
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let visible: Bool
    /// Drifting in the space card.
    var floats = false

    init(state: NotchPanel.State, tab: NotchController.Model.Tab, mirror: Bool, hud: Bool, greeting: Bool,
         cover: Bool, space: Bool, width: CGFloat, height: CGFloat) {
        // Content starts under the 8 pt top and the 34 pt header; the bean sits a little low.
        let cardCentre: CGFloat = 99
        switch state {
        case .expanded where greeting: (x, y, size, visible) = (width / 2, 93, 78, true)
        // The photo booth: small, top left, before its title (user's choice, 2026-10-23).
        case .expanded where tab == .mirror: (x, y, size, visible) = (25, 21, 18, true)
        // Nothing playing: big, in the middle of the space card (before the cover's corner,
        // which a paused track's artwork would otherwise claim).
        case .expanded where !mirror && tab == .home && space: (x, y, size, visible, floats) = (10 + 322 / 2, cardCentre - 6, 76, true, true)
        case .expanded where !mirror && tab == .home && cover:
            let corner = FocusCard.coverCentre.x + 10 + FocusCard.coverSize / 2 - 4
            (x, y, size, visible) = (corner, 42 + FocusCard.coverCentre.y + FocusCard.coverSize / 2 - 6, 24, true)
        case .expanded where !mirror && tab == .home: (x, y, size, visible) = (62, cardCentre, 66, true)
        case .expanded where !mirror && tab == .ask: (x, y, size, visible) = (52, cardCentre, 44, true)
        case .peek where !hud: (x, y, size, visible) = (40, height / 2, 20, true)
        default: (x, y, size, visible) = (46, 16, 6, false)
        }
    }
}

/// The bean adrift in space: a slow bob, sway and tilt (still with Reduce Motion).
private struct SpaceFloat: ViewModifier {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !on || reduceMotion)) { timeline in
            let t = on && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 0
            content
                .offset(x: CGFloat(sin(t * 0.7)) * 5, y: CGFloat(sin(t * 1.3)) * 5)
                .rotationEffect(.degrees(sin(t * 0.9) * 6))
        }
    }
}

// MARK: - Peek

/// The peek's right side: the visualizer while music plays (the bean is on the left).
private struct PeekContent: View {
    let music: MusicBridge

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            if music.hasTrack {
                Visualizer(playing: music.isPlaying && music.soundOut, color: NotchPalette.lifted(music.tint, 0.45, fallback: NotchPalette.music))
                    .frame(width: 18, height: 14)
                    .padding(.trailing, 22)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Closed, music playing

/// The artwork on the left wing, a visualizer on the right (GIF 1.6 s on).
private struct ActivityWings: View {
    let music: MusicBridge
    let art: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if music.artwork == nil {
                    // No cover (a video without Internet Mode's thumbnail): the bean, not a ♪ tile.
                    BeanFace(mood: .idle, eyes: .both(.pill()), size: 20, badge: false)
                } else {
                    Artwork(music: music, corner: 5)
                }
            }
                .matchedGeometryEffect(id: "art", in: art)
                .frame(width: 22, height: 22)
                .padding(.leading, 9)
            Spacer(minLength: 0)
            Visualizer(playing: music.isPlaying && music.soundOut, color: NotchPalette.lifted(music.tint, 0.45, fallback: NotchPalette.music))
                .frame(width: 18, height: 14)
                .padding(.trailing, 11)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Four bars that bob while playing (drawn only then; still when paused and with Reduce Motion).
private struct Visualizer: View {
    let playing: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !playing || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { index in
                    let wave = playing && !reduceMotion ? (sin(time * (6 + Double(index) * 1.9) + Double(index) * 1.3) + 1) / 2 : 0.35
                    Capsule().fill(color).frame(width: 2.5, height: 5 + 9 * wave)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Volume HUD

/// The volume keys' HUD as a Pac-Man level (user's design, 2026-10-23): on arcade blue, the
/// speaker in the left wing and the percentage in the right, in the arcade font; under the
/// notch a corridor of 20 pellets as wide as the HUD. Pac-Man stands at the level: turning it
/// up he chomps right and the pellets behind him turn green, turning it down he backs up and
/// they turn red again. Muted, he greys out and every pellet is red. Reduce Motion: he jumps.
private struct HUDWings: View {
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
        HStack(spacing: 7) {
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

// MARK: - Open

/// The open island: a 34 pt header (tabs left: home, ask, shelf; settings, sounds and close
/// right), then 98 pt of cards. Home: the focus card (the bean on its left; the music, or
/// ClickBait's keys) and four pills; Ask: a field for the chat; Shelf: files, AirDrop, note.
private struct OpenNotch: View {
    let model: NotchController.Model
    let music: MusicBridge
    let shelf: ShelfStore
    @Bindable var settings: AppSettings
    let onTabChange: (NotchController.Model.Tab) -> Void
    let onMirror: () -> Void
    let onCollapse: () -> Void
    /// A new one each time the notch opens (this view is rebuilt then).
    @State private var cheer = NotchCheer.next(after: nil)

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 34)
            Group {
                switch model.tab {
                case .home where model.greeting: GreetingCard().frame(height: 98).transition(.opacity)
                case .home: home.transition(.opacity.combined(with: .scale(scale: 0.97)))
                case .ask where model.chatting:
                    if let chat = model.chat { ChatView(model: chat, inNotch: true).padding(.bottom, 2).transition(.opacity) }
                case .ask:
                    AskCard(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                case .shelf: ShelfView(shelf: shelf, note: model.note, onEditing: { model.editing = $0 }).transition(.opacity.combined(with: .scale(scale: 0.97)))
                case .music: MusicPanel(music: music).transition(.opacity.combined(with: .scale(scale: 0.97)))
                case .settings, .mirror: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 10)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .foregroundStyle(NotchPalette.text)
        // The ⓘ card hangs under its button over the cards, as HeyClicky's does.
        .overlay(alignment: .topTrailing) {
            if model.showsKeys {
                KeysCard {
                    model.showsKeys = false
                    model.settingsPage = .shortcuts
                    onTabChange(.settings)
                }
                .padding(.top, 32)
                .padding(.trailing, 44)  // under the ⓘ
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: model.showsKeys)
        .onChange(of: model.tab) { _, _ in model.showsKeys = false }
    }

    private var header: some View {
        HStack(spacing: 0) {
            // A cheer in place of the tabs (Ask and Shelf are pills): clicked, it goes home, or
            // at home says something new. Same type as the companion's pills.
            Button {
                if model.showsKeys { model.showsKeys = false } else if model.tab == .home { cheer = NotchCheer.next(after: cheer) } else { onTabChange(.home) }
            } label: {
                Text(cheer)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchPalette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .animation(.easeOut(duration: 0.2), value: cheer)
            .help(model.tab == .home ? "Something new" : "Back to Home")
            .accessibilityLabel(model.tab == .home ? cheer : "Back to Home: \(cheer)")
            Spacer()
            HStack(spacing: 14) {
                NotchHeaderIcon(symbol: model.showsKeys ? "info.circle.fill" : "info.circle", label: "Shortcuts", on: model.showsKeys) {
                    model.showsKeys.toggle()
                }
                NotchHeaderIcon(symbol: model.tab == .settings ? "gearshape.fill" : "gearshape", label: "ClickBait settings") {
                    model.settingsPage = .general
                    onTabChange(.settings)
                }
                NotchHeaderIcon(symbol: "xmark", label: "Close", action: onCollapse)
            }
            .padding(.trailing, 16)
        }
        .frame(maxHeight: .infinity)
    }

    private var home: some View {
        HStack(spacing: 10) {
            FocusCard(music: music, mood: model.mood(), health: model.health)
                .frame(width: 322)
                .notchCard(wash: FocusCard.wash(for: model.mood()))
            // Laid out as the Windows logo's four squares, each square keeping its colour (user's
            // choice, 2026-10-23): Ask first, top-left in red; Music bottom-right in yellow.
            IslandPills(pills: [
                .init(name: "Ask", mood: .thinking, eyes: .both(.pill()), tint: NotchPalette.windowsRed) { onTabChange(.ask) },
                .init(name: "Shelf", mood: .happy, eyes: .both(.chevron), tint: NotchPalette.windowsGreen) { onTabChange(.shelf) },
                .init(name: "Mirror", mood: .idle, eyes: .both(.dot), holo: true, tint: NotchPalette.windowsBlue, action: onMirror),
                .init(name: music.sourceName ?? "Music", mood: .idle, eyes: .both(.pill(tilt: 8)), tint: NotchPalette.windowsYellow) {
                    onTabChange(.music)
                },
            ])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .notchCard()
        }
        .frame(height: 98)
    }
}

/// The home's left card. On its left: the track's cover with the bean small on its corner, or
/// the bean large when there's no cover (`BeanPlace`). The words start at 108 pt:
/// a dot, a title and a source, then two lines — the track's position and controls, or how
/// to reach ClickBait. ↗ opens the player.
private struct FocusCard: View {
    let music: MusicBridge
    let mood: Bean.Mood
    /// Shown instead of "ready" while nothing is going on and something isn't ready (`HealthLadder`).
    let health: HealthLadder.Item?

    /// The cover, in the card's points.
    nonisolated static let coverSize: CGFloat = 66
    nonisolated static let coverCentre = CGPoint(x: 52, y: 49)

    /// Music playing: the player. Otherwise (paused too) deep space, with the bean in the
    /// middle (`BeanPlace`), a warning only if something needs fixing, and a way back to a
    /// paused track.
    static func showsSpace(_ music: MusicBridge) -> Bool { !(music.hasTrack && music.isPlaying) }

    var body: some View {
        let space = Self.showsSpace(music)
        ZStack {
            if space { spaceCard.transition(.opacity) } else { playerCard.transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.4), value: space)
        .onAppear { music.refresh() }
    }

    private var modelNote: HealthLadder.Item? {
        NotchBean.isResting(mood) ? health.flatMap { $0 == .ready ? nil : $0 } : nil
    }

    private var spaceCard: some View {
        ZStack(alignment: .topLeading) {
            SpaceScene()
            // Only when something needs fixing (the model, a permission): no "ready" line.
            if let modelNote {
                HStack(spacing: 6) {
                    Circle().fill(modelNote.color).frame(width: 7, height: 7)
                    Text(modelNote.shortWords).font(.system(size: 11)).foregroundStyle(NotchPalette.secondary).lineLimit(1)
                }
                .padding(.top, 10)
                .padding(.leading, 12)
            }
            if music.hasTrack {
                Button { music.send("playpause") } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                        Text(music.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(NotchPalette.text)
                    .padding(.horizontal, 9)
                    .frame(height: 20)
                    .background(Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(music.title)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 10)
                .padding(.bottom, 9)
                .frame(maxWidth: 120, alignment: .leading)  // clear of the bean in the middle
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Look.Corner.card, style: .continuous))
    }

    private var playerCard: some View {
        let modelNote = modelNote
        let accent = music.hasTrack ? NotchPalette.lifted(music.tint, 0.45, fallback: NotchPalette.music)
            : modelNote?.color ?? NotchBean.color(for: mood)
        return ZStack(alignment: .topLeading) {
            if music.hasTrack, music.artwork != nil {
                Artwork(music: music, corner: Look.Corner.tile)
                    .frame(width: Self.coverSize, height: Self.coverSize)
                    .overlay(RoundedRectangle(cornerRadius: Look.Corner.tile, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    .onTapGesture { music.openPlayer() }
                    .help("Open \(music.sourceName ?? "the player")")
                    .position(Self.coverCentre)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            // As boring.notch's player: the title bold, the artist under it in the cover's
            // colour, then the progress and the buttons.
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: music.hasTrack ? music.title : "ClickBait", font: .system(size: 12, weight: .semibold))
                    .padding(.trailing, 30)
                Text(music.hasTrack ? music.artist : modelNote?.shortWords ?? Self.status(mood))
                    .font(.system(size: 11))
                    .foregroundStyle(music.hasTrack ? accent : NotchPalette.secondary)
                    .lineLimit(1)
                    .padding(.trailing, 30)
                PlayerControls(music: music, accent: accent)
                    .frame(height: 44, alignment: .top)
                    .padding(.top, 5)
                    .padding(.trailing, 12)
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.top, 4)
            if music.sourceName != nil {
                // ✕: stop the music and go back to the bean in space (the cover opens the player).
                Button { music.stop() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color(hex: 0x8A8F98))
                        .frame(width: 16, height: 16)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Stop the music")
                .accessibilityLabel("Stop the music")
                .padding(.top, 8)
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The card's wash: the state's colour rising from below while something is going on.
    static func wash(for mood: Bean.Mood) -> Color? {
        switch mood {
        case .listening, .thinking, .working, .happy, .error: NotchBean.color(for: mood).opacity(0.45)
        case .idle, .sleepy, .panicked, .warm, .tired, .hello: nil
        }
    }

    private static func status(_ mood: Bean.Mood) -> String {
        switch mood {
        case .listening: "listening"
        case .thinking: "thinking"
        case .working: "on it"
        case .happy: "done"
        case .error: "something went wrong"
        case .idle, .sleepy, .panicked, .warm, .tired, .hello: "ready"
        }
    }
}

/// The track's progress and its buttons (the home card and the Music panel).
private struct PlayerControls: View {
    let music: MusicBridge
    let accent: Color

    var body: some View {
        // YouTube: no shuffle or repeat; its time only when the browser lets ClickBait read it.
        let youtube = music.youtubeTab != nil && music.player == nil
        return VStack(alignment: .leading, spacing: 5) {
            if !youtube || music.duration > 0 {
                TimelineView(.animation(minimumInterval: 0.5, paused: !music.isPlaying)) { context in
                    PlayerProgress(position: music.currentPosition(at: context.date), duration: music.duration,
                                   accent: accent, onSeek: { music.seek(to: $0) })
                }
            }
            HStack(spacing: 12) {
                if !youtube {
                    PlayerIconButton(symbol: "shuffle", size: 10, tint: music.shuffling ? accent : NotchPalette.tertiary,
                                     label: music.shuffling ? "Shuffle on" : "Shuffle off") { music.setShuffling(!music.shuffling) }
                }
                PlayerIconButton(symbol: "backward.fill", size: 11, tint: NotchPalette.control, label: "Previous track") {
                    music.send("previous track")
                }
                Button { music.send("playpause") } label: {
                    ZStack {
                        Circle().fill(NotchPalette.text)
                        Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 8.5, weight: .bold)).foregroundStyle(NotchPalette.ink)
                            .offset(x: music.isPlaying ? 0 : 1)
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(PlayerPressStyle())
                .accessibilityLabel(music.isPlaying ? "Pause" : "Play")
                PlayerIconButton(symbol: "forward.fill", size: 11, tint: NotchPalette.control, label: "Next track") {
                    music.send("next track")
                }
                if !youtube {
                    PlayerIconButton(symbol: "repeat", size: 10, tint: music.repeating ? accent : NotchPalette.tertiary,
                                     label: music.repeating ? "Repeat on" : "Repeat off") { music.setRepeating(!music.repeating) }
                }
            }
        }
    }
}

/// A title that runs sideways when it's longer than its space (user's ask, 2026-10-23): it
/// rests at the start, scrolls through at 30 pt/s, and comes round again; one that fits, or
/// Reduce Motion, stays still and is cut with "…".
struct MarqueeText: View {
    let text: String
    let font: Font
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var started = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gap: CGFloat = 36, speed: CGFloat = 30, rest = 2.0

    var body: some View {
        let runs = textWidth > boxWidth + 1 && boxWidth > 0 && !reduceMotion
        Text(text).font(font).lineLimit(1)
            .opacity(runs ? 0 : 1)  // sets the height; shows when it fits
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .background(alignment: .leading) {
                Text(text).font(font).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if runs {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let cycle = textWidth + Self.gap
                        let period = Double(cycle / Self.speed) + Self.rest
                        let t = context.date.timeIntervalSince(started).truncatingRemainder(dividingBy: period)
                        HStack(spacing: Self.gap) { Text(text); Text(text) }
                            .font(font).fixedSize()
                            .offset(x: t < Self.rest ? 0 : -CGFloat(t - Self.rest) * Self.speed)
                    }
                    .frame(width: boxWidth, alignment: .leading)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                                 .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: text) { _, _ in started = Date() }
            .accessibilityLabel(text)
    }
}

/// The ⓘ card: the main keys with Edit opening Settings' Shortcuts page.
private struct KeysCard: View {
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard").font(.system(size: 10))
                Text("Shortcuts").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(action: onEdit) {
                    Label("Edit", systemImage: "gearshape").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).frame(height: 19)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 5)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.bottom, 5)
            VStack(spacing: 3) {
                ForEach(ShortcutList.items.filter { ["Push to talk", "Explain", "Text mode", "Dictate"].contains($0.title) }) { item in
                    HStack(spacing: 6) {
                        Text(item.short).font(.system(size: 10, weight: .semibold)).foregroundStyle(NotchPalette.text)
                        Spacer(minLength: 6)
                        ShortcutKeys(item: item, compact: true)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 260)
        .background(Color(hex: 0x1C1D21), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 10, y: 4)
    }
}

/// The Music pill's panel (user's choice, 2026-10-23: the notch turns into the music
/// controls): the cover big, the track and its controls, and the three sources down the right
/// — the one playing marked; clicking another opens it (YouTube: its tab, else the site).
private struct MusicPanel: View {
    let music: MusicBridge

    var body: some View {
        let accent = NotchPalette.lifted(music.tint, 0.45, fallback: NotchPalette.bubblegum)
        HStack(spacing: 10) {
            HStack(spacing: 14) {
                Artwork(music: music, corner: Look.Corner.tile)
                    .frame(width: 76, height: 76)
                    .overlay(RoundedRectangle(cornerRadius: Look.Corner.tile, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    .onTapGesture { music.openPlayer() }
                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(text: music.hasTrack ? music.title : "Nothing playing", font: .system(size: 14, weight: .semibold))
                    Text(music.hasTrack ? music.artist : "Pick a player on the right")
                        .font(.system(size: 11)).foregroundStyle(music.hasTrack ? accent : NotchPalette.secondary).lineLimit(1)
                    if music.hasTrack {
                        PlayerControls(music: music, accent: accent).padding(.top, 5)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(width: 430)
            .frame(maxHeight: .infinity)
            .notchCard(wash: music.hasTrack ? accent.opacity(0.22) : nil)
            VStack(spacing: 4) {
                source("Apple Music", on: music.player == .music) { music.open(.music) }
                source("Spotify", on: music.player == .spotify) { music.open(.spotify) }
                source("YouTube", on: music.youtubeTab != nil && music.player == nil) {
                    if music.youtubeTab != nil { music.openPlayer() } else { MusicBridge.openYouTube() }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .notchCard()
        }
        .frame(height: 98)
    }

    private func source(_ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(on ? NotchPalette.bubblegum : NotchPalette.tertiary.opacity(0.5)).frame(width: 6, height: 6)
                Text(name).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                if on, music.isPlaying, music.soundOut {
                    Visualizer(playing: true, color: NotchPalette.bubblegum).frame(width: 12, height: 9)
                }
            }
            .foregroundStyle(on ? NotchPalette.text : NotchPalette.secondary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(on ? NotchPalette.bubblegum.opacity(0.14) : NotchPalette.ink, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "\(name), playing from here" : "Open \(name)")
    }
}

/// The home's right card: four pills, two by two, each with a small bean.
private struct IslandPills: View {
    struct Pill: Identifiable {
        let name: String
        let mood: Bean.Mood
        let eyes: Bean.EyePair
        /// Chrome and rainbow instead of the mood's colour (Mirror).
        var holo = false
        /// A colour of its own instead of the mood's.
        var tint: Color?
        /// Dark eyes on a light colour (the yellow); white on the others.
        var inkEyes: Bool { tint == NotchPalette.windowsYellow }
        var action: () -> Void = {}
        var id: String { name }
    }

    let pills: [Pill]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
            ForEach(pills) { IslandPill(pill: $0) }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IslandPill: View {
    let pill: IslandPills.Pill
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: pill.action) { face }
            .buttonStyle(.plain)
            .modifier(lift)
    }

    private var lift: PillLift { PillLift(hovering: $hovering, label: pill.name) }

    private var face: some View {
        let color = pill.tint ?? NotchBean.color(for: pill.mood)
        return ZStack {
                Capsule().fill(hovering ? color.opacity(0.18) : NotchPalette.ink)
                Capsule().stroke(color.opacity(hovering ? 0.55 : 0.14), lineWidth: 1)
                HStack(spacing: 0) {
                    Gazing { look in
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !pill.holo || reduceMotion)) { timeline in
                            BeanFace(mood: pill.mood, eyes: pill.eyes, size: 22, look: look, badge: false, solid: true, holo: pill.holo,
                                     sheen: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate,
                                     tint: pill.tint, eyeColor: pill.inkEyes ? NotchPalette.ink : nil)
                        }
                    }
                        .frame(width: 22, height: 22)
                        .padding(.leading, 8)
                    Spacer()
                }
                Text(pill.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? color : NotchPalette.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .shadow(color: color.opacity(hovering ? 0.35 : 0), radius: 10, y: 2)
    }
}

/// A pill's hover: it grows and brightens a touch.
private struct PillLift: ViewModifier {
    @Binding var hovering: Bool
    let label: String

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.04 : 1)
            .brightness(hovering ? 0.06 : 0)
            .onHover { hover in withAnimation(Look.Motion.press) { hovering = hover } }
            .accessibilityLabel(label)
    }
}

/// The launch hello's card: sparkles twinkling around the bean (placed by `BeanPlace`).
private struct GreetingCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let sparkles: [(x: Double, y: Double, r: Double, phase: Double)] = {
        var random = SystemRandomNumberGenerator()
        return (0..<90).map { _ in
            (Double.random(in: 0...1, using: &random), Double.random(in: 0...1, using: &random),
             Double.random(in: 0.4...1.2, using: &random), Double.random(in: 0...(2 * .pi), using: &random))
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for spark in Self.sparkles {
                    // Thicker away from the middle, where the bean is.
                    let dx = spark.x - 0.5, dy = spark.y - 0.5
                    guard dx * dx * 4 + dy * dy > 0.06 else { continue }
                    let alpha = reduceMotion ? 0.5 : 0.25 + 0.6 * (sin(time * 2.2 + spark.phase) + 1) / 2
                    let rect = CGRect(x: spark.x * size.width, y: spark.y * size.height, width: spark.r * 2, height: spark.r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))
                }
            }
        }
        .notchCard()
        .accessibilityHidden(true)
    }
}

/// The ask tab: a field for ClickBait's chat, with the bean beside it. Return sends it to the
/// chat (and the notch folds).
/// Typing a question: Return sends it to ClickBait's chat (the same one as double-tap ⌥⌘),
/// says so for a moment (`sentHold`), then folds.
private struct AskCard: View {
    let model: NotchController.Model
    @State private var typing = false
    @State private var text = ""
    @State private var voice: FollowUpPanel.Voice = .ready
    @FocusState private var focused: Bool

    /// The dock card's follow-up pair (user's ask, 2026-10-23): text opens the field, voice
    /// records until stop and asks what it heard. The notch stays open meanwhile.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if typing {
                HStack(spacing: 8) {
                    TextField("Type a question, then Return", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(text.isEmpty ? NotchPalette.tertiary : CompanionTone.processing.color)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty)
                    .accessibilityLabel("Ask")
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(NotchPalette.ink, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
            } else {
                HStack(spacing: 6) {
                    Button { typing = true; focused = true } label: { Label("text", systemImage: "character.cursor.ibeam") }
                        .buttonStyle(AquaButtonStyle(selected: false))
                        .accessibilityLabel("Ask by typing")
                    VoiceButton(voice: voice, level: model.micLevel, action: tapVoice)
                }
            }
        }
        .padding(.leading, 86)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .notchCard(wash: CompanionTone.processing.color.opacity(voice == .recording ? 0.4 : 0.22))
        .animation(.easeOut(duration: 0.2), value: typing)
        .onChange(of: focused) { _, now in model.editing = now || voice.isBusy }
        .onChange(of: voice) { _, now in model.editing = focused || now.isBusy }
        .onDisappear {
            if voice == .recording { model.voiceCancel() }
            model.editing = false
        }
    }

    private var title: String {
        switch voice {
        case .recording: "Listening… tap stop when you're done"
        case .starting: "Starting the microphone…"
        case .transcribing: "Working out what you said…"
        case .failed(let reason): reason
        case .ready: "Ask ClickBait"
        }
    }

    private func send() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        text = ""
        model.ask(question)
    }

    private func tapVoice() {
        switch voice {
        case .starting, .transcribing:
            return
        case .recording:
            voice = .transcribing
            Task { @MainActor in
                switch await model.voiceFinish() {
                case .success(let heard) where heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    voice = .failed("Didn't hear anything. Tap voice to try again.")
                case .success(let heard):
                    voice = .ready
                    model.ask(heard)
                case .failure(let error):
                    voice = .failed(error.message)
                }
            }
        case .ready, .failed:
            voice = .starting
            if let reason = model.voiceStart() { voice = .failed(reason) } else { voice = .recording }
        }
    }
}

@MainActor
private final class CameraMirrorModel: ObservableObject {
    enum State {
        case starting
        case denied
        case unavailable
        case failed(String)
        case ready
    }

    /// One photo: a thumbnail, and its file in a temporary folder until it's saved.
    struct Shot: Identifiable {
        let id = UUID()
        let image: NSImage
        let file: URL
    }

    @Published private(set) var state: State = .starting
    /// Newest first, at most `maxShots`.
    @Published private(set) var shots: [Shot] = []
    static let maxShots = 4
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var configured = false
    /// Unsaved shots live here and go when the booth closes.
    private let scratch = FileManager.default.temporaryDirectory.appending(path: "ClickBait Mirror", directoryHint: .isDirectory)

    func start() {
        Task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureAndRun()
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted { configureAndRun() } else { state = .denied }
            case .denied, .restricted:
                state = .denied
            @unknown default:
                state = .unavailable
            }
        }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        if case .ready = state { state = .starting }  // a countdown still running takes no photo
        shots = []
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Takes a photo, flipped to match the mirrored preview, and keeps it as the newest shot.
    func snap() async -> Bool {
        guard case .ready = state, let data = await PhotoGrab.take(from: photoOutput),
              let rep = NSBitmapImageRep(data: data), let source = rep.cgImage,
              let flipped = Self.mirrored(source),
              let jpeg = NSBitmapImageRep(cgImage: flipped).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return false }
        guard session.isRunning else { return false }  // closed while the photo was on its way
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let file = scratch.appending(path: "Mirror \(Self.stamp()).jpg")
            try jpeg.write(to: file)
            let image = NSImage(cgImage: flipped, size: NSSize(width: flipped.width, height: flipped.height))
            shots.insert(Shot(image: image, file: file), at: 0)
            for old in shots.dropFirst(Self.maxShots) { try? FileManager.default.removeItem(at: old.file) }
            shots = Array(shots.prefix(Self.maxShots))
            return true
        } catch {
            return false
        }
    }

    /// Copies every shot to ~/Pictures/ClickBait and shows them in Finder.
    func saveAll() {
        guard !shots.isEmpty,
              let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first else { return }
        let folder = pictures.appending(path: "ClickBait", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = shots.compactMap { shot -> URL? in
            let target = folder.appending(path: shot.file.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) { return target }
            return (try? FileManager.default.copyItem(at: shot.file, to: target)) != nil ? target : nil
        }
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
    }

    private static func mirrored(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.translateBy(x: CGFloat(image.width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return format.string(from: Date())
    }

    private func configureAndRun() {
        guard !configured else {
            if !session.isRunning { session.startRunning() }
            state = .ready
            return
        }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            state = .unavailable
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            session.beginConfiguration()
            session.sessionPreset = .high
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                state = .failed("The camera could not be connected.")
                return
            }
            session.addInput(input)
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            session.commitConfiguration()
            configured = true
            session.startRunning()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// One `AVCapturePhotoOutput` capture as an async call: the photo's data, or nil on failure.
private final class PhotoGrab: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    // shortcut: one capture at a time per grab (the booth's countdown allows only one), guarded by the lock.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var data: Data?

    @MainActor static func take(from output: AVCapturePhotoOutput) async -> Data? {
        let grab = PhotoGrab()
        return await withCheckedContinuation { continuation in
            grab.lock.withLock { grab.continuation = continuation }
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: grab)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.withLock { data = error == nil ? photo.fileDataRepresentation() : nil }
    }

    /// Always the last call, success or not.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        lock.withLock {
            continuation?.resume(returning: data)
            continuation = nil
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewHost {
        let view = CameraPreviewHost()
        view.wantsLayer = true
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        Self.mirror(view.previewLayer.connection)
        return view
    }

    func updateNSView(_ view: CameraPreviewHost, context: Context) {
        view.previewLayer.session = session
        Self.mirror(view.previewLayer.connection)
    }

    /// AVFoundation throws if mirroring is set while it still adjusts it automatically.
    private static func mirror(_ connection: AVCaptureConnection?) {
        guard let connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}

private final class CameraPreviewHost: NSView {
    override func makeBackingLayer() -> CALayer { AVCaptureVideoPreviewLayer() }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

/// The Mirror photo booth: the mirrored camera on the left; on the right the shutter (a 3-2-1
/// countdown, then a flash), the last four shots (drag one out, or save them all to
/// ~/Pictures/ClickBait) and the way back. Unsaved shots are deleted when it closes.
private struct PhotoBooth: View {
    @StateObject private var camera = CameraMirrorModel()
    let onClose: () -> Void
    @State private var count: Int?
    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Mirror").font(.system(size: 12, weight: .semibold))
                    .padding(.leading, 20)  // after the bean (`BeanPlace`)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close mirror")
            }
            .foregroundStyle(NotchPalette.text)
            .padding(.horizontal, 16)
            .frame(height: 26)
            HStack(alignment: .top, spacing: 10) {
                viewfinder.frame(width: 420, height: 236)
                controls
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private var viewfinder: some View {
        ZStack {
            Color(white: 0.06)
            switch camera.state {
            case .ready:
                CameraPreview(session: camera.session)
            case .starting:
                status("camera", "Starting camera…")
            case .denied:
                status("camera.badge.ellipsis", "Allow camera access in System Settings")
            case .unavailable:
                status("camera.metering.unknown", "No front camera available")
            case .failed(let message):
                status("exclamationmark.camera", message)
            }
            if let count {
                Text("\(count)")
                    .font(.system(size: 96, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 12)
                    .contentTransition(.numericText(countsDown: true))
                    .accessibilityLabel("Photo in \(count)")
            }
            Color.white.opacity(flash ? 0.9 : 0).allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var controls: some View {
        let ready = if case .ready = camera.state { true } else { false }
        return VStack(spacing: 10) {
            Button(action: shoot) {
                ZStack {
                    Circle().fill(.white).frame(width: 52, height: 52)
                    Circle().stroke(.white.opacity(0.5), lineWidth: 2).frame(width: 60, height: 60)
                    Image(systemName: "camera.fill").font(.system(size: 18)).foregroundStyle(Color.black)
                }
            }
            .buttonStyle(.plain)
            .disabled(!ready || count != nil)
            .opacity(ready && count == nil ? 1 : 0.4)
            .accessibilityLabel("Take a photo")
            LazyVGrid(columns: [GridItem(.fixed(84), spacing: 6), GridItem(.fixed(84), spacing: 6)], spacing: 6) {
                ForEach(0..<CameraMirrorModel.maxShots, id: \.self) { index in
                    shotTile(index < camera.shots.count ? camera.shots[index] : nil)
                }
            }
            Button("Save to Pictures") { camera.saveAll() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(camera.shots.isEmpty ? NotchPalette.secondary : NotchPalette.text)
                .padding(.horizontal, 12).frame(height: 24)
                .background(NotchPalette.ink, in: Capsule())
                .disabled(camera.shots.isEmpty)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func shotTile(_ shot: CameraMirrorModel.Shot?) -> some View {
        let tile = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let shot {
            Image(nsImage: shot.image).resizable().scaledToFill()
                .frame(width: 84, height: 47).clipShape(tile)
                .onDrag { NSItemProvider(contentsOf: shot.file) ?? NSItemProvider() }
                .help("Drag the photo out")
                .accessibilityLabel("Photo, drag to save it somewhere")
        } else {
            tile.stroke(NotchPalette.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 84, height: 47)
                .accessibilityHidden(true)
        }
    }

    /// 3, 2, 1, flash, photo.
    private func shoot() {
        Task { @MainActor in
            for tick in [3, 2, 1] {
                withAnimation(reduceMotion ? nil : .snappy) { count = tick }
                try? await Task.sleep(for: .seconds(0.8))
            }
            count = nil
            flash = true
            _ = await camera.snap()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { flash = false }
        }
    }

    private func status(_ symbol: String, _ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.white.opacity(0.8))
            Text(message).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }
}

/// The artwork, or a dim tile with a note when there's none.
private struct Artwork: View {
    let music: MusicBridge
    let corner: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Group {
            if let image = music.artwork {
                // A square crop of any shape (a video's 16:9 thumbnail): the clear square takes
                // the frame it's given, the picture fills it and is cut to it.
                Color.clear.overlay { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            } else {
                shape.fill(Color.white.opacity(0.1)).overlay(Image(systemName: "music.note").foregroundStyle(NotchPalette.secondary))
            }
        }
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

// MARK: - Shelf

/// The shelf's AirDrop pad. Drop files on it, or click it to send the shelf's selection (all of
/// the shelf when nothing is selected): macOS's own AirDrop window opens with the people and
/// devices nearby (`AirDropSender`). The pad says what it will send, then how it went.
private struct AirDropPad: View {
    let shelf: ShelfStore
    @State private var targeted = false

    var body: some View {
        let sender = shelf.airDrop
        Button {
            sender.send(NotchPanel.airDropItems(shelf: shelf.files, selected: shelf.selectedFiles))
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol(sender.status))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(NotchPalette.highlight)
                    .symbolEffect(.pulse, isActive: targeted || isChoosing(sender.status))
                    .contentTransition(.symbolEffect(.replace))
                Text("AirDrop").font(.system(size: 12, weight: .semibold)).foregroundStyle(NotchPalette.text)
                Text(subtitle(sender.status))
                    .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                    .multilineTextAlignment(.center).lineLimit(2)
                    .padding(.horizontal, 8)
            }
            .frame(width: 120)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .notchCard(wash: targeted ? NotchPalette.highlight.opacity(0.45) : nil)
        .overlay {
            RoundedRectangle(cornerRadius: Look.Corner.card, style: .continuous)
                .strokeBorder(NotchPalette.highlight, lineWidth: 1.5)
                .opacity(targeted ? 1 : 0)
        }
        .scaleEffect(targeted ? 1.03 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            let files = NotchPanel.airDropItems(dropped: urls, shelf: [], selected: [])
            guard !files.isEmpty else { return false }
            sender.send(files)
            return true
        } isTargeted: { targeted = $0 }
        .help("Drop files to AirDrop them, or click to AirDrop the shelf's files")
        .accessibilityLabel("AirDrop")
        .accessibilityValue(subtitle(sender.status))
        .accessibilityHint("Opens the AirDrop window to choose a person or device nearby")
    }

    private func isChoosing(_ status: AirDropSender.Status) -> Bool {
        if case .choosing = status { true } else { false }
    }

    private func symbol(_ status: AirDropSender.Status) -> String {
        switch status {
        case .sent: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .idle, .choosing: "dot.radiowaves.up.forward"
        }
    }

    private func subtitle(_ status: AirDropSender.Status) -> String {
        switch status {
        case .choosing(let count): return "Choose who gets \(count == 1 ? "it" : "all \(count)")…"
        case .sent(let count): return count == 1 ? "Sent" : "Sent \(count) files"
        case .failed(let message): return message
        case .idle:
            if targeted { return "Release to AirDrop" }
            if !shelf.selectedFiles.isEmpty { return "Send \(shelf.selectedFiles.count) selected" }
            if !shelf.files.isEmpty { return shelf.files.count == 1 ? "Send the file" : "Send all \(shelf.files.count)" }
            return "Drop files to send"
        }
    }
}

/// Cards: the files dropped here (drag out to use, click to select, right-click to
/// show in Finder), the AirDrop pad and the quick note.
private struct ShelfView: View {
    let shelf: ShelfStore
    @Bindable var note: NotchController.Note
    let onEditing: (Bool) -> Void
    @State private var targeted = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            files
            AirDropPad(shelf: shelf)
            noteCard
        }
        .frame(height: 124)
    }

    /// Files: a count, select all and drag-the-selection, and the drop area.
    private var files: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Files").font(.system(size: 12, weight: .semibold))
                Text("\(shelf.files.count)/12").font(.system(size: 10).monospacedDigit()).foregroundStyle(NotchPalette.tertiary)
                Spacer(minLength: 4)
                if shelf.files.count > 1 {
                    Button(shelf.selectedFiles.count == shelf.files.count ? "Clear" : "Select all") {
                        if shelf.selectedFiles.count == shelf.files.count { shelf.clearSelection() } else { shelf.selectAll() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchPalette.highlight)
                }
                if !shelf.selectedFiles.isEmpty {
                    ZStack {
                        Capsule().fill(NotchPalette.highlight.opacity(0.16))
                        MultiFileDragHandle(urls: shelf.files.filter { shelf.selectedFiles.contains($0) })
                        Label("Drag \(shelf.selectedFiles.count)", systemImage: "hand.draw")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NotchPalette.highlight)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .allowsHitTesting(false)
                    }
                    .fixedSize()
                    .accessibilityElement()
                    .accessibilityLabel("Drag \(shelf.selectedFiles.count) selected files together")
                    .accessibilityHint("Drag this control to share the selected files together")
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: Look.Corner.tile, style: .continuous)
                    .strokeBorder(targeted ? NotchPalette.highlight : Color.white.opacity(0.12),
                                  style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: shelf.files.isEmpty ? [4, 4] : []))
                if shelf.files.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 15)).foregroundStyle(NotchPalette.highlight)
                        Text(targeted ? "Release to add" : "Drop files here")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(NotchPalette.secondary)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { ForEach(shelf.files, id: \.self) { file($0) } }
                            .padding(.horizontal, 5)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                shelf.add(files)
                return !files.isEmpty
            } isTargeted: { targeted = $0 }
            .accessibilityLabel(shelf.files.isEmpty ? "Shelf, empty. Drop files here." : "Shelf, \(shelf.files.count) files")
        }
        .padding(10)
        .frame(width: 250)
        .notchCard(wash: targeted ? NotchPalette.highlight.opacity(0.35) : nil)
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Note").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                NotchHeaderIcon(symbol: "list.bullet", label: "Add bullet", action: appendBullet)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $note.text)
                    .font(.system(size: 13))
                    .foregroundColor(NotchPalette.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .tint(NotchPalette.highlight)
                    .focused($noteFocused)
                    .accessibilityLabel("Quick note")
                if note.text.isEmpty {
                    Text("Write a note…")
                        .font(.system(size: 13))
                        .foregroundStyle(NotchPalette.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchCard()
        .overlay(RoundedRectangle(cornerRadius: Look.Corner.card, style: .continuous)
            .strokeBorder(NotchPalette.highlight.opacity(noteFocused ? 0.5 : 0), lineWidth: 1))
        .animation(.easeOut(duration: 0.14), value: noteFocused)
        .onChange(of: noteFocused) { _, now in onEditing(now) }
    }

    private func appendBullet() {
        if note.text.isEmpty || note.text.hasSuffix("\n") {
            note.text += "• "
        } else {
            note.text += "\n• "
        }
    }

    private func file(_ url: URL) -> some View {
        let selected = shelf.selectedFiles.contains(url)
        return VStack(spacing: 2) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
            Text(url.lastPathComponent).font(.system(size: 9, weight: .medium))
                .foregroundStyle(NotchPalette.secondary).lineLimit(1).frame(width: 54)
        }
        .frame(width: 58, height: 62)
        .background(selected ? NotchPalette.highlight.opacity(0.16) : Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: Look.Corner.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Look.Corner.tile, style: .continuous)
            .strokeBorder(selected ? NotchPalette.highlight.opacity(0.75) : Color.white.opacity(0.07), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if selected {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(NotchPalette.highlight)
                    .background(Color.black, in: Circle()).offset(x: -2, y: -2)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { shelf.remove(url) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(NotchPalette.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(url.lastPathComponent) from the shelf")
        }
        .onTapGesture { shelf.toggleSelection(url) }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button(shelf.selectedFiles.contains(url) ? "Deselect" : "Select") { shelf.toggleSelection(url) }
            Button("Remove from shelf", role: .destructive) { shelf.remove(url) }
        }
        .draggable(url)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityHint(selected ? "Selected for a group drag. Click to deselect, or drag this file individually." : "Click to select for a group drag, or drag this file individually.")
    }
}
