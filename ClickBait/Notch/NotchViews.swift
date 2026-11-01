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

/// The open notch is showing and done moving: its own animations (the stars) run only then.
private struct NotchLiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var notchLive: Bool {
        get { self[NotchLiveKey.self] }
        set { self[NotchLiveKey.self] = newValue }
    }
}

struct NotchView: View {
    let model: NotchController.Model
    /// The display this panel is on: unless the notch is open here, it draws folded.
    var displayID: UInt32?
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
    /// The four squares' beans and their tabs' header badges: the one clicked flies to the
    /// top left (user's idea, 2026-10-24), and back into its square on the way home.
    @Namespace private var tabBeans

    /// Settings' way back, named after the tab it came from.
    private static func backLabel(_ tab: NotchController.Model.Tab) -> String {
        switch tab {
        case .shelf: "Back to Shelf"
        case .ask: "Back to Ask"
        case .home, .settings, .mirror, .music: "Back to Home"
        }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Open (or showing a HUD) on this display; the others draw folded.
    private var isHere: Bool {
        model.state == .collapsed && model.hud == nil || model.activeDisplay == nil || displayID == nil || model.activeDisplay == displayID
    }
    private var state: NotchPanel.State { isHere ? model.state : .collapsed }
    private var hud: (level: Double, muted: Bool, sky: Bool)? { isHere ? model.hud : nil }

    var body: some View {
        let open = state == .expanded
        let prompter = isHere ? NotchController.prompter : nil
        let look = NotchPanel.shape(state, notch: notch, activity: model.activity, hud: hud != nil,
                                    shelf: model.tab == .shelf, settings: model.tab == .settings, mirror: model.tab == .mirror,
                                    chat: model.showsChat, prompter: prompter)
        let ear = CGFloat(NotchPanel.ear)
        let shape = NotchShape(ear: ear, bottom: CGFloat(look.radius))
        // The open size for this tab, whatever the state: the open content is laid out at it
        // once and keeps it while it fades out, so closing fades instead of cutting off.
        let openLook = NotchPanel.shape(.expanded, notch: notch, activity: model.activity, hud: false,
                                        shelf: model.tab == .shelf, settings: model.tab == .settings, mirror: model.tab == .mirror,
                                        chat: model.showsChat, prompter: prompter)
        let openFrame = CGSize(width: CGFloat(openLook.width), height: CGFloat(openLook.height))
        let place = BeanPlace(state: state, tab: model.tab, mirror: model.tab == .mirror || model.showsChat, hud: hud != nil,
                              greeting: model.greeting, cover: music.hasTrack && music.artwork != nil, space: FocusCard.showsSpace(music),
                              width: CGFloat(look.width), height: CGFloat(look.height))
        // Folded with nothing to show: no black block, only a small see-through handle, as
        // HeyClicky's (user's choice, 2026-10-23). The black grows in from it as it opens.
        let resting = state == .collapsed && !model.activity && hud == nil
        ZStack(alignment: .top) {
            // Solid almost at once, so the shape grows out of the handle instead of fading in
            // on the same spring (half-see-through for the first frames).
            shape.fill(Color.black.opacity(resting ? 0 : 1))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: resting)
            if resting {
                // Only when the pointer comes near: faded out quickly otherwise (user's ask).
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 60, height: 5)
                    .padding(.top, 8)
                    .opacity(model.nearNotch ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: model.nearNotch)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            // The open panel (Home, Ask, Shelf, Music) stays built and is revealed, so opening
            // only grows the shape: building it in the spring's frames dropped 2–5 frames each
            // open, up to 686 ms the first time (frame probe, 2026-10-25).
            if keepsOpenPanel {
                OpenNotch(model: model, music: music, shelf: shelf, settings: settings, tabBeans: tabBeans,
                          onTabChange: onTabChange, onMirror: { onTabChange(.mirror) }, onCollapse: onCollapse)
                    .frame(width: openFrame.width, height: openFrame.height, alignment: .top)
                    .padding(.horizontal, ear)
                    .frame(width: CGFloat(look.width) + 2 * ear, height: CGFloat(look.height), alignment: .top)
                    // In just after the shape starts growing; out at once when it folds.
                    .opacity(open ? 1 : 0)
                    .animation(reduceMotion ? nil : open ? .easeOut(duration: 0.22).delay(0.08) : .easeIn(duration: 0.1), value: open)
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
            }
            Group {
                if open {
                    if model.tab == .mirror, prompter != nil {
                        // The notch *is* the prompter: the same window, sprung to its size.
                        PrompterView(studio: .shared)
                            .frame(width: openFrame.width, height: openFrame.height, alignment: .top)
                            .transition(.opacity)
                    } else if model.tab == .mirror {
                        PhotoBooth(tabBeans: tabBeans) { onTabChange(.home) }
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
                    }
                } else if let hud = hud, hud.sky {
                    SkyWings(level: hud.level)
                } else if let hud = hud {
                    HUDWings(level: hud.level, muted: hud.muted)
                } else if state == .peek {
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
            NotchBean(mood: model.greeting ? .hello : model.mood(), size: place.size, awake: open,
                      toyFace: place.floats ? SpaceToyPlay.shared.face : nil, shown: place.visible)
                .modifier(SpaceFloat(on: place.floats && !SpaceToyPlay.shared.toy.isMoving))
                .modifier(SpaceToyHandle(on: place.floats, radius: place.size / 2))
                // Standing in for a video's missing thumbnail on Home: clicking it goes there too.
                .modifier(OpenOnTap(on: open && model.tab == .home && music.hasTrack && music.isPlaying && music.artwork == nil,
                                    label: "Open \(music.sourceName ?? "the player")") {
                    music.openPlayer()
                    onCollapse()
                })
                .position(x: ear + place.x, y: place.y)
                .opacity(place.visible ? 1 : 0)
                .allowsHitTesting(place.visible)
        }
        .contentShape(shape)
        // Anything dropped anywhere on the notch goes on the shelf; dragged over the closed
        // notch, it opens on the shelf (`ShelfDrop`).
        .onDrop(of: ShelfDrop.types, isTargeted: Binding(get: { false }, set: { if $0, !open { onDragIn() } })) { providers in
            ShelfDrop.take(providers, into: shelf)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // One curve for the whole motion: growing or tab-changing springs, folding eases out.
        // (Width and height used to always take the opening spring, even while folding.)
        .animation(reduceMotion || StudioModel.shared.resizing ? nil : spring(open: state != .collapsed),
                   value: Motion(state: state, tab: model.tab, width: look.width, height: look.height, activity: model.activity))
        .environment(\.notchLive, open && model.settled)
        .accessibilityElement(children: open ? .contain : .ignore)
        .accessibilityLabel(open ? "ClickBait notch" : model.activity ? "Now playing: \(music.title)" : "ClickBait notch, closed")
        .accessibilityHint(open ? "" : "Click to open")
        .accessibilityAddTraits(open ? [] : .isButton)
    }

    /// Home, Ask, Shelf and Music: kept built; Mirror (the camera) and Settings build on demand.
    private var keepsOpenPanel: Bool { isHere && model.tab != .mirror && model.tab != .settings }

    /// Everything the notch's shape follows, animated as one.
    private struct Motion: Equatable {
        let state: NotchPanel.State
        let tab: NotchController.Model.Tab
        let width: Double
        let height: Double
        let activity: Bool
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
        // The cards start under the 8 pt top and the 34 pt header and are 98 pt tall: their
        // middle is 91 pt down (it was 99, so the bean sat 8 pt low, user's catch 2026-10-24).
        let cardCentre: CGFloat = 8 + 34 + 98 / 2
        switch state {
        case .expanded where greeting: (x, y, size, visible) = (width / 2, 93, 78, true)
        // The tabs show their square's bean in the header instead (user's idea, 2026-10-24).
        case .expanded where tab == .mirror: (x, y, size, visible) = (25, 21, 18, false)
        // Nothing playing: big, in the middle of the space card (before the cover's corner,
        // which a paused track's artwork would otherwise claim).
        case .expanded where !mirror && tab == .home && space: (x, y, size, visible, floats) = (10 + 322 / 2, cardCentre, 76, true, true)
        case .expanded where !mirror && tab == .home && cover:
            let corner = FocusCard.coverCentre.x + 10 + FocusCard.coverSize / 2 - 4
            (x, y, size, visible) = (corner, 42 + FocusCard.coverCentre.y + FocusCard.coverSize / 2 - 6, 24, true)
        case .expanded where !mirror && tab == .home: (x, y, size, visible) = (62, cardCentre, 66, true)
        case .expanded where !mirror && tab == .ask: (x, y, size, visible) = (25, 25, 18, false)
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

// MARK: - Open

/// The open island: a 34 pt header (tabs left: home, ask, shelf; settings, sounds and close
/// right), then 98 pt of cards. Home: the focus card (the bean on its left; the music, or
/// ClickBait's keys) and four pills; Ask: a field for the chat; Shelf: files, AirDrop, note.
private struct OpenNotch: View {
    let model: NotchController.Model
    let music: MusicBridge
    let shelf: ShelfStore
    @Bindable var settings: AppSettings
    let tabBeans: Namespace.ID
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
                case .music: MusicPanel(music: music, onOpen: { music.openPlayer(); onCollapse() }).transition(.opacity.combined(with: .scale(scale: 0.97)))
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
        // Kept built between opens now: a new cheer each time it opens.
        .onChange(of: model.state) { _, state in if state == .expanded { cheer = NotchCheer.next(after: cheer) } }
    }

    private var header: some View {
        HStack(spacing: 0) {
            // In a tab: its square's bean, flown up from Home.
            if let pill = IslandPills.pill(for: model.tab, music: music) {
                TabBean(pill: pill, size: 18)
                    .matchedGeometryEffect(id: model.tab, in: tabBeans)
                    .padding(.leading, 14)
                    .padding(.trailing, -8)
                    .accessibilityHidden(true)
            }
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
                InternetSwitch(internet: settings.internet)
                NotchHeaderIcon(symbol: model.showsKeys ? "info.circle.fill" : "info.circle", label: "Shortcuts", on: model.showsKeys) {
                    model.showsKeys.toggle()
                }
                NotchHeaderIcon(symbol: model.tab == .settings ? "gearshape.fill" : "gearshape", label: "ClickBait settings") {
                    model.settingsPage = .general
                    onTabChange(.settings)
                }
                // In a tab (Ask, Shelf, Music, a chat): back to the main panel; at Home: fold.
                NotchHeaderIcon(symbol: "xmark", label: model.tab == .home ? "Close" : "Back to Home") {
                    if model.tab == .home { onCollapse() } else { onTabChange(.home) }
                }
            }
            .padding(.trailing, 16)
        }
        .frame(maxHeight: .infinity)
    }

    private var home: some View {
        HStack(spacing: 10) {
            FocusCard(music: music, mood: model.mood(), health: model.health, onOpen: { music.openPlayer(); onCollapse() })
                .frame(width: 322)
                .notchCard(wash: FocusCard.wash(for: model.mood()))
            // Laid out as the Windows logo's four squares, each square keeping its colour (user's
            // choice, 2026-10-23): Ask first, top-left in red; Music bottom-right in yellow.
            IslandPills(pills: [NotchController.Model.Tab.ask, .shelf, .mirror, .music].compactMap { tab in
                IslandPills.pill(for: tab, music: music).map { pill in
                    var pill = pill
                    pill.action = tab == .mirror ? onMirror : { onTabChange(tab) }
                    return pill
                }
            }, tabBeans: tabBeans, showing: model.tab)
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
    /// The cover clicked: to the player or the video's tab, and the notch folds (user's ask, 2026-10-26).
    let onOpen: () -> Void

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
                    .modifier(TakeMeThere())
                    .onTapGesture { onOpen() }
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Open \(music.sourceName ?? "the player")")
                    .accessibilityAction { onOpen() }
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
    @Environment(\.notchLive) private var live

    var body: some View {
        // YouTube: no shuffle or repeat; its time only when the browser lets ClickBait read it.
        let youtube = music.youtubeTab != nil && music.player == nil
        return VStack(alignment: .leading, spacing: 5) {
            if !youtube || music.duration > 0 {
                TimelineView(.animation(minimumInterval: 0.5, paused: !live || !music.isPlaying)) { context in
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
    @Environment(\.notchLive) private var live

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
                    // Home and Music stay built while the notch is folded. Don't keep
                    // animating a clipped title in that retained, invisible panel.
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live)) { context in
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
    /// The cover clicked: to the player or the video's tab, and the notch folds.
    let onOpen: () -> Void

    var body: some View {
        let accent = NotchPalette.lifted(music.tint, 0.45, fallback: NotchPalette.bubblegum)
        HStack(spacing: 10) {
            HStack(spacing: 14) {
                Artwork(music: music, corner: Look.Corner.tile)
                    .frame(width: 76, height: 76)
                    .overlay(RoundedRectangle(cornerRadius: Look.Corner.tile, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    .modifier(TakeMeThere())
                    .onTapGesture { onOpen() }
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Open \(music.sourceName ?? "the player")")
                    .accessibilityAction { onOpen() }
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
struct IslandPills: View {
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
        /// The tab it opens (its bean flies to that tab's header).
        var tab: NotchController.Model.Tab = .home
        var id: String { name }
    }

    let pills: [Pill]
    let tabBeans: Namespace.ID
    /// The tab open now: its square's bean is up in the header, not here.
    let showing: NotchController.Model.Tab

    /// Each square's look, in one place for the square and its tab's header.
    static func pill(for tab: NotchController.Model.Tab, music: MusicBridge?) -> Pill? {
        switch tab {
        case .ask: Pill(name: "Ask", mood: .thinking, eyes: .both(.pill()), tint: NotchPalette.windowsRed, tab: .ask)
        case .shelf: Pill(name: "Shelf", mood: .happy, eyes: .both(.chevron), tint: NotchPalette.windowsGreen, tab: .shelf)
        case .mirror: Pill(name: "Studio", mood: .idle, eyes: .both(.dot), holo: true, tint: NotchPalette.windowsBlue, tab: .mirror)
        case .music: Pill(name: music?.sourceName ?? "Music", mood: .idle, eyes: .both(.pill(tilt: 8)), tint: NotchPalette.windowsYellow, tab: .music)
        case .home, .settings: nil
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
            ForEach(pills) { IslandPill(pill: $0, tabBeans: tabBeans, away: $0.tab == showing) }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IslandPill: View {
    let pill: IslandPills.Pill
    let tabBeans: Namespace.ID
    /// Its tab is open: the bean is in the header.
    let away: Bool
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
        // A see-through shade of its own colour, the four names in one dark grey (user's choice,
        // 2026-10-24); the bean sits on a soft dark halo so it stands out from the same colour.
        return ZStack {
                // A light, see-through shade of its colour: the colour over a frosted white, so the
                // dark grey name and the full-colour bean both stand out against it.
                Capsule().fill(.white.opacity(hovering ? 0.62 : 0.55))
                Capsule().fill(color.opacity(hovering ? 0.62 : 0.5))
                Capsule().fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
                Capsule().stroke(.white.opacity(hovering ? 0.6 : 0.35), lineWidth: 1)
                HStack(spacing: 0) {
                    TabBean(pill: pill, size: 22)
                        .matchedGeometryEffect(id: pill.tab, in: tabBeans, isSource: !away)
                        .opacity(away ? 0 : 1)
                        .shadow(color: .black.opacity(0.45), radius: 2.5, y: 1)
                        .padding(.leading, 8)
                    Spacer()
                }
                Text(pill.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(NotchPalette.pillText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .shadow(color: color.opacity(hovering ? 0.35 : 0), radius: 10, y: 2)
    }
}

/// A square's bean (solid in its colour, the Mirror's holo), watching the pointer: in its
/// square at Home, in its tab's header elsewhere.
struct TabBean: View {
    let pill: IslandPills.Pill
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notchLive) private var live

    var body: some View {
        Gazing { look in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !pill.holo || reduceMotion || !live)) { timeline in
                BeanFace(mood: pill.mood, eyes: pill.eyes, size: size, look: look, badge: false, solid: true, holo: pill.holo,
                         sheen: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate,
                         tint: pill.tint, eyeColor: pill.inkEyes ? NotchPalette.ink : nil)
            }
        }
        .frame(width: size, height: size)
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
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .notchCard(wash: CompanionTone.processing.color.opacity(voice == .recording ? 0.4 : 0.22))
        .animation(.easeOut(duration: 0.2), value: typing)
        .onChange(of: focused) { _, now in model.editing = now || voice.isBusy }
        .onChange(of: voice) { _, now in model.editing = focused || now.isBusy }
        .onChange(of: model.voiceDrops) { _, _ in if voice == .recording { voice = .ready } }
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

/// Hands its AppKit view to `found`, so AppKit UI (the AirDrop popover) can be pinned to it.
private struct ViewAnchor: NSViewRepresentable {
    let found: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// The shelf's AirDrop pad. Drop files on it, or click it to send the shelf's selection (all of
/// the shelf when nothing is selected): macOS's own AirDrop window opens with the people and
/// devices nearby (`AirDropSender`). The pad says what it will send, then how it went.
private struct AirDropPad: View {
    let shelf: ShelfStore
    @State private var targeted = false

    var body: some View {
        let sender = shelf.airDrop
        let items = AirDropSender.sendable(NotchPanel.airDropItems(shelf: shelf.files, selected: shelf.selectedFiles))
        Button {
            sender.send(items)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol(sender.status))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(NotchPalette.highlight)
                    .symbolEffect(.pulse, isActive: targeted || isChoosing(sender.status))
                    .contentTransition(.symbolEffect(.replace))
                Text("AirDrop").font(.system(size: 12, weight: .semibold)).foregroundStyle(NotchPalette.text)
                Text(subtitle(sender.status, sending: items.count))
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
        // Cumulative (user's ask, 2026-11-01): a drop joins the selection, and AirDrop offers
        // everything selected, the number the pad shows.
        .dropDestination(for: URL.self) { urls, _ in
            let files = AirDropSender.sendable(NotchPanel.airDropItems(dropped: urls, shelf: [], selected: []))
            guard !files.isEmpty else { return false }
            shelf.select(files)
            sender.send(NotchPanel.airDropItems(shelf: shelf.files, selected: shelf.selectedFiles))
            return true
        } isTargeted: { targeted = $0 }
        .background(ViewAnchor { sender.padView = $0 })
        .help("Drop files to AirDrop them, or click to AirDrop the shelf's files")
        .accessibilityLabel("AirDrop")
        .accessibilityValue(subtitle(sender.status, sending: items.count))
        .accessibilityHint("Opens the AirDrop window to choose a person or device nearby")
    }

    private func isChoosing(_ status: AirDropSender.Status) -> Bool {
        if case .choosing = status { true } else { false }
    }

    private func symbol(_ status: AirDropSender.Status) -> String {
        switch status {
        case .failed: "exclamationmark.triangle.fill"
        case .idle, .choosing: "dot.radiowaves.up.forward"
        }
    }

    /// `sending`: how many files a click hands over (`AirDropSender.sendable`), the one count shown.
    private func subtitle(_ status: AirDropSender.Status, sending: Int) -> String {
        switch status {
        case .choosing(let count): return "Choose who gets \(count == 1 ? "it" : "all \(count)")…"
        case .failed(let message): return message
        case .idle:
            if targeted { return "Release to AirDrop" }
            if sending == 0 { return "Drop files to send" }
            if !shelf.selectedFiles.isEmpty { return "Send \(sending) selected" }
            return sending == 1 ? "Send the file" : "Send all \(sending)"
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
    @State private var noteFocused = false
    /// A word in the note's header for a moment ("copied", "sent to Notes"), and what Clear
    /// took, for its undo.
    @State private var noteStatus: String?
    /// The file being renamed from its tile (user's ask, 2026-11-01), and the name being typed.
    @State private var renaming: URL?
    @State private var newName = ""
    @FocusState private var renameFocused: Bool
    @State private var cleared: String?

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
                Button("Paste") { ShelfDrop.paste(into: shelf) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchPalette.highlight)
                    .help("Paste what you copied onto the shelf (⌘V)")
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
                        Text(targeted ? "Release to add" : "Drop or paste files here")
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
            .onDrop(of: ShelfDrop.types, isTargeted: $targeted) { ShelfDrop.take($0, into: shelf) }
            // A click here makes the notch key, so ⌘V pastes onto the shelf; right-click ▸ Paste too.
            .simultaneousGesture(TapGesture().onEnded { ShelfDrop.focusNotch() })
            .contextMenu {
                Button("Paste") { ShelfDrop.paste(into: shelf) }.disabled(!ShelfDrop.canPaste)
            }
            .onAppear {
                ShelfDrop.shelfShown = true
                ShelfDrop.listenForPaste(shelf: shelf)
            }
            .onDisappear { ShelfDrop.shelfShown = false }
            .accessibilityLabel(shelf.files.isEmpty ? "Shelf, empty. Drop files here." : "Shelf, \(shelf.files.count) files")
        }
        .padding(10)
        .frame(width: 250)
        .notchCard(wash: targeted ? NotchPalette.highlight.opacity(0.35) : nil)
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let cleared {
                    Button("cleared · undo") { note.textView?.replaceAll(with: cleared); self.cleared = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchPalette.highlight)
                } else {
                    Text(noteStatus ?? "Note").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(noteStatus == nil ? NotchPalette.text : NotchPalette.highlight)
                }
                Spacer(minLength: 2)
                NotchHeaderIcon(symbol: "list.bullet", label: "Bullet this line") { onCaret(NoteEditing.toggleBullet) }
                NotchHeaderIcon(symbol: "checklist", label: "Checkbox on this line") { onCaret(NoteEditing.toggleCheckbox) }
                NotchHeaderIcon(symbol: "doc.on.doc", label: "Copy the note", action: copyNote)
                NotchHeaderIcon(symbol: "note.text.badge.plus", label: "Send to Notes", action: sendToNotes)
                NotchHeaderIcon(symbol: "trash", label: "Clear the note", action: clearNote)
            }
            ZStack(alignment: .topLeading) {
                NoteTextView(note: note) { focused in
                    noteFocused = focused
                    onEditing(focused)
                }
                if note.text.isEmpty {
                    Text("Write a note…")
                        .font(.system(size: 13))
                        .foregroundStyle(NotchPalette.tertiary)
                        .padding(.leading, 5).padding(.top, 2)
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
    }

    /// A list button: acts on the line the caret is on (the end, if the note isn't being typed in).
    private func onCaret(_ edit: (String, Int) -> NoteEditing.Edit) {
        guard let box = note.textView else { return }
        let caret = box.window?.firstResponder === box ? box.selectedRange().location : (note.text as NSString).length
        box.apply(edit(note.text, caret))
        box.window?.makeFirstResponder(box)
    }

    private func copyNote() {
        guard !note.text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
        flash("copied")
    }

    private func sendToNotes() {
        let text = note.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        flash("sending…")
        Task { @MainActor in
            do {
                _ = try await ActionExecutor.run(.makeNote(text))
                flash("sent to Notes")
            } catch {
                flash("couldn't reach Notes")
            }
        }
    }

    /// Clear, with a few seconds to undo (⌘Z works too).
    private func clearNote() {
        guard !note.text.isEmpty else { return }
        let was = note.text
        note.textView?.replaceAll(with: "")
        if note.textView == nil { note.text = "" }
        cleared = was
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if cleared == was { cleared = nil }
        }
    }

    private func flash(_ words: String) {
        noteStatus = words
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if noteStatus == words { noteStatus = nil }
        }
    }

    /// From the menu as from a double-click: the notch takes the keyboard (a right-click
    /// doesn't make it key) and the field is ready to type into at once.
    private func startRename(_ url: URL) {
        newName = url.lastPathComponent
        renaming = url
        NSApp.windows.first { $0.isVisible && $0.canBecomeKey && $0.level == WindowLayers.notch }?.makeKey()
        Task { @MainActor in renameFocused = true }
    }

    /// Renames the file on disk, in its own folder; a name without an extension keeps the old one.
    private func finishRename(_ url: URL) {
        defer { renaming = nil }
        do {
            let renamed = try shelf.rename(url, to: newName)
            if renamed != url { flash("renamed to \(renamed.lastPathComponent)") }
        } catch {
            flash("couldn't rename: \(error.localizedDescription)")
        }
    }

    private func file(_ url: URL) -> some View {
        let selected = shelf.selectedFiles.contains(url)
        return VStack(spacing: 2) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
            if renaming == url {
                TextField("Name", text: $newName)
                    .textFieldStyle(.plain).font(.system(size: 9, weight: .medium)).foregroundStyle(NotchPalette.text)
                    .multilineTextAlignment(.center).frame(width: 54)
                    .padding(.vertical, 1).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    .focused($renameFocused)
                    .onSubmit { finishRename(url) }
                    .onExitCommand { renaming = nil }
                    .accessibilityLabel("New name for \(url.lastPathComponent)")
            } else {
                Text(url.lastPathComponent).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NotchPalette.secondary).lineLimit(1).frame(width: 54)
                    .onTapGesture(count: 2) { startRename(url) }
            }
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
            Button("Rename…") { startRename(url) }
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

/// Internet Mode in the notch's header (user's ask, 2026-10-25): a sliding Aqua switch in
/// light blue both ways (user's choice), "local" with a lock on the left or "online" with a
/// globe on the right. Same switch as the menu bar's.
struct InternetSwitch: View {
    let internet: InternetMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 76
    static let height: CGFloat = 22
    private static let onTop = Color(red: 0.82, green: 0.92, blue: 0.99)
    private static let onBottom = Color(red: 0.61, green: 0.79, blue: 0.92)
    private static let rim = Color(red: 0.36, green: 0.57, blue: 0.73)

    var body: some View {
        let on = internet.isOn
        Button { internet.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(LinearGradient(colors: [Self.onTop, Self.onBottom], startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.04)],
                                                           startPoint: .top, endPoint: .center)).padding(1))
                    .overlay(Capsule().strokeBorder(Self.rim.opacity(0.6), lineWidth: 0.7))
                Text(on ? "online" : "local")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(on ? .trailing : .leading, Self.height - 2)
                Circle()
                    .fill(LinearGradient(colors: [.white, Color(white: 0.88)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .overlay(Image(systemName: on ? "globe" : "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.black))
                    .frame(width: Self.height - 4, height: Self.height - 4)
                    .padding(2)
            }
            .frame(width: Self.width, height: Self.height)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: on)
        }
        .buttonStyle(.plain)
        .help(on ? "Online: lookups and thumbnails can go online. Click for local only." : "Local: nothing leaves this Mac. Click to go online.")
        .accessibilityLabel("Internet Mode")
        .accessibilityValue(on ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The cover (or the bean standing in for it) under the pointer: it lifts a little, the
/// pointer becomes a hand, and the companion's pill says "take me there!" (user's ask,
/// 2026-11-01: nothing showed the cover could be clicked).
struct TakeMeThere: ViewModifier {
    /// Set by the app delegate: the pill's words, or nil to take them away.
    @MainActor static var say: ((String?) -> Void)?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? 1.05 : 1)
            .animation(Look.Motion.press, value: hovering)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                Self.say?(inside ? "take me there!" : nil)
            }
            .onDisappear {
                if hovering { NSCursor.pop(); Self.say?(nil) }
            }
    }
}

/// A tap that does `action`, only while `on` (the bean standing in for a cover).
private struct OpenOnTap: ViewModifier {
    let on: Bool
    let label: String
    let action: () -> Void

    func body(content: Content) -> some View {
        if on {
            content
                .modifier(TakeMeThere())
                .onTapGesture(perform: action)
                .help(label)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text(label), action)
        } else {
            content
        }
    }
}
