import AppKit
import ClickBaitCore
import SwiftUI

/// Studio's teleprompter: a black panel hanging from the notch, right under the camera, so
/// reading looks like eye contact. Never in screen sharing, recordings or screenshots
/// (`sharingType = .none`). Resized from its bottom corners; scrolls by itself at the set
/// speed, or with the trackpad; a cue picked in Studio jumps there.
@MainActor
final class PrompterController {
    static let shared = PrompterController()
    private var panel: NSPanel?
    private var scrollMonitor: Any?

    func show() {
        let panel = panel ?? make()
        // Trackpad and mouse-wheel scrolling over it (it never takes keyboard focus).
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.panel else { return event }
                StudioModel.shared.scroll(by: -(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8))
                return nil
            }
        }
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
        // Under the notch panel (same layer): hovering the notch still opens it over the prompter.
        if let notch = NSApp.windows.first(where: { $0 !== panel && $0.isVisible && $0.level == WindowLayers.notch }) {
            panel.order(.below, relativeTo: notch.windowNumber)
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// New size from a drag (or the cue list): in the notch, the notch springs to it.
    func resize(to size: CGSize) {
        if StudioModel.shared.inNotch { StudioModel.shared.notchChanged?(); return }
        guard let panel else { return }
        place(panel, size: size)
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = WindowLayers.notch
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.sharingType = .none  // invisible to screen sharing, recordings and screenshots
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: PrompterView(studio: .shared))
        return panel
    }

    /// The cue list's room under the prompter, when it's open.
    static func cueListHeight(_ cues: Int) -> CGFloat {
        CGFloat(min(max(cues, 1), 6)) * 30 + 16
    }

    /// Room under the prompter: the cue bar whenever there are cues, and the list when open.
    static func below(_ studio: StudioModel) -> CGFloat {
        let cues = studio.script.cues.count
        guard studio.cueBarShown else { return 0 }
        return 6 + CueBar.height + (studio.cuesOpen ? 6 + cueListHeight(cues) : 0)
    }

    /// Top-centred on the screen with the notch (the camera), else the main screen; floating,
    /// its top centre where it was left. Taller by the cue list when it hangs open below.
    private func place(_ panel: NSPanel, size: CGSize? = nil) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let studio = StudioModel.shared
        var size = size ?? studio.size
        size.height += Self.below(studio)
        var top = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
        if studio.floating {
            top = studio.floatAt ?? CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 60)
        }
        panel.setFrame(NSRect(x: top.x - size.width / 2, y: top.y - size.height, width: size.width, height: size.height), display: true)
    }

    /// Floating: moved by a drag (its top centre follows the pointer).
    func move(by delta: CGSize, from start: CGPoint) {
        guard let panel else { return }
        let studio = StudioModel.shared
        studio.floatAt = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        place(panel)
    }

    /// The top centre now (where a move starts from).
    var topCentre: CGPoint? {
        panel.map { CGPoint(x: $0.frame.midX, y: $0.frame.maxY) }
    }

    /// The notch's height on that screen: where the text can start without hiding behind it.
    static var notchHeight: CGFloat {
        (NSScreen.screens.first { $0.safeAreaInsets.top > 0 }?.safeAreaInsets.top).map { $0 } ?? 0
    }

    /// The notch's own size: where the morph starts from (and ends, going away).
    static var notchSize: CGSize {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return CGSize(width: 200, height: 32) }
        return CGSize(width: max(120, screen.frame.width - left.width - right.width), height: screen.safeAreaInsets.top)
    }
}

struct PrompterView: View {
    @Bindable var studio: StudioModel
    private var hovering: Bool { studio.hovering }
    @State private var hideTask: Task<Void, Never>?
    @State private var lineTops: [Int: CGFloat] = [:]
    @State private var contentHeight: CGFloat = 0
    @State private var dragStart: CGSize?
    @State private var moveStart: (mouse: NSPoint, top: CGPoint)?
    @State private var lastTick: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the text starts: under the notch, or near the top when floating.
    private var top: CGFloat { studio.floating ? 14 : max(PrompterController.notchHeight, 10) + 8 }
    private static let shape = UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)

    /// The script's lines, numbered: cues and the voice's place meet them by line.
    private var lines: [(index: Int, text: String)] {
        studio.script.readable.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { ($0.offset, String($0.element)) }
    }

    var body: some View {
        VStack(spacing: 6) {
            prompter
            // Like Moody's: a small bar under the prompter — previous, "2 / 7" (the list), next —
            // and the list hanging under it.
            if studio.cueBarShown, studio.shown {
                CueBar(studio: studio)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                if studio.cuesOpen {
                    CueList(studio: studio)
                        .frame(width: min(studio.size.width, 360))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(width: studio.size.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        // Over the prompter or its bar: the buttons and the bar are in; they go a moment after
        // the pointer leaves (time to travel down to the bar), the bar staying while the list is open.
        .onHover { inside in
            hideTask?.cancel()
            if inside {
                withAnimation(.easeOut(duration: 0.15)) { studio.hovering = true }
            } else {
                hideTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.2)) { studio.hovering = false }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: studio.cuesOpen)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: studio.cueBarShown)
    }

    /// The prompter's size now: the notch's while it grows out of it, its own once shown.
    private var current: CGSize { studio.shown ? studio.size : PrompterController.notchSize }

    private var prompter: some View {
        ZStack(alignment: .bottom) {
            Self.shape.fill(Color.black)
            QuicksilverRing(level: studio.level, reduceMotion: reduceMotion)
                .frame(width: studio.size.width, height: studio.size.height)
                .clipShape(Self.shape)
                .allowsHitTesting(false)
            Group {
                text
                if hovering || studio.cuesOpen { controls.transition(.opacity) }
            }
            .opacity(studio.shown ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: studio.shown ? 0.3 : 0.12).delay(studio.shown ? 0.22 : 0), value: studio.shown)
        }
        .frame(width: studio.size.width, height: studio.size.height)
        .overlay { if studio.shown { ResizeEdges(studio: studio) } }
        // The morph: the black shape grows from the notch's size to the prompter's (springy,
        // like the notch's own opening), the text fading in once it's nearly there.
        .frame(width: current.width, height: current.height, alignment: .top)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: studio.floating ? 22 : 0, bottomLeadingRadius: studio.shown ? 22 : 10,
                                          bottomTrailingRadius: studio.shown ? 22 : 10, topTrailingRadius: studio.floating ? 22 : 0,
                                          style: .continuous))
        // Floating: dragged anywhere by its body.
        .gesture(studio.floating ? DragGesture(minimumDistance: 3).onChanged { _ in
            let mouse = NSEvent.mouseLocation
            let begin = moveStart ?? (mouse, PrompterController.shared.topCentre ?? .zero)
            moveStart = begin
            PrompterController.shared.move(by: CGSize(width: mouse.x - begin.mouse.x, height: mouse.y - begin.mouse.y), from: begin.top)
        }.onEnded { _ in moveStart = nil } : nil)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.48, dampingFraction: 0.8), value: studio.shown)
        .frame(width: studio.size.width, alignment: .top)
        .onChange(of: studio.jump) { _, target in
            guard let target else { return }
            let line = studio.script.line(of: target)
            withAnimation(.easeInOut(duration: 0.35)) { studio.offset = max(0, (lineTops[line] ?? 0) - 4) }
            studio.jump = nil
        }
        .onChange(of: studio.playing) { _, _ in lastTick = nil }
    }

    /// The script, scrolling up; lines fade in at the bottom and out under the notch.
    private var text: some View {
        TimelineView(.animation(paused: !studio.playing && !studio.following)) { timeline in
            VStack(alignment: .center, spacing: 6) {
                ForEach(lines, id: \.index) { line in
                    // A blank line between sections is a small gap, not a whole empty line of
                    // big text (user: "why the dead space?"). Monospaced like the cues and
                    // Moody's prompter (user's choice).
                    Text(line.text.trimmingCharacters(in: .whitespaces).isEmpty ? "" : line.text)
                        .font(.system(size: studio.fontSize, weight: .medium, design: .monospaced))
                        .frame(height: line.text.trimmingCharacters(in: .whitespaces).isEmpty ? 4 : nil)
                        .foregroundStyle(MoodyLook.cream)  // the cues' and buttons' white (user's ask)
                        .multilineTextAlignment(.center)
                        // Wraps to as many lines as it needs (the prompter's fixed height
                        // squeezed each to one, cut off with "…": found in the live test).
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: LineTops.self, value: [line.index: proxy.frame(in: .named("script")).minY])
                        })
                }
            }
            .padding(.horizontal, 24)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in Color.clear.preference(key: ContentHeight.self, value: proxy.size.height) })
            .coordinateSpace(name: "script")
            .offset(y: -studio.offset)
            .onChange(of: timeline.date) { _, now in advance(to: now) }
            .onChange(of: studio.offset) { _, offset in
                // The line at the top of what's showing is where reading is.
                studio.readingLine = lines.last(where: { (lineTops[$0.index] ?? 0) <= offset + 8 })?.index ?? 0
            }
        }
        .onPreferenceChange(LineTops.self) { lineTops = $0 }
        .onPreferenceChange(ContentHeight.self) { contentHeight = $0; studio.maxOffset = max(0, $0 - 20) }
        .frame(width: studio.size.width, height: studio.size.height - top, alignment: .top)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                     .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func advance(to now: Date) {
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let elapsed = now.timeIntervalSince(last)
        if studio.following {
            // At your pace: while you speak the reading position runs on at your words a second
            // (up to 6 words past the last match), still the moment you stop; each match corrects it.
            guard let place = studio.place, let follower = studio.follower else { return }
            if studio.speaking {
                studio.reading = min(studio.reading + studio.pace * elapsed, Double(place.word) + 6)
            }
            guard let spot = follower.placement(ofWord: studio.reading), let top = lineTops[spot.line] else { return }
            let bottom = lineTops[spot.line + 1] ?? contentHeight
            let target = max(0, top + (bottom - top) * spot.fraction - (studio.size.height - self.top) * 0.35)
            let step = (target - studio.offset) * min(1, elapsed * 4)
            if abs(step) > 0.05 { studio.offset = min(max(0, studio.offset + step), studio.maxOffset) }
            return
        }
        guard studio.playing else { return }
        nudge(by: studio.speed * elapsed)
        if studio.offset >= max(0, contentHeight - 20) { studio.playing = false }  // the end
    }

    private func nudge(by points: Double) {
        studio.scroll(by: points)
    }

    /// On hover: play or pause, slower and faster, the cues, text size, close; and the
    /// bottom-right corner resizes.
    private var controls: some View {
        HStack(spacing: 6) {
            // One button (user: "why is there a voice button and a play button… confusing"):
            // it follows your voice — at your pace — or it's paused. ⌃⌘P does the same.
            PrompterButton(symbol: studio.following ? "pause.fill" : "play.fill",
                           help: studio.following ? "Pause (⌃⌘P)" : "Carry on: follows your voice (⌃⌘P)") {
                studio.togglePause()
            }
            PrompterButton(symbol: "textformat.size.smaller", help: "Smaller text") { studio.fontSize = max(14, studio.fontSize - 2) }
            PrompterButton(symbol: "textformat.size.larger", help: "Bigger text") { studio.fontSize = min(44, studio.fontSize + 2) }
            Spacer()
            PrompterButton(symbol: studio.floating ? "pin.fill" : "macwindow.on.rectangle",
                           help: studio.floating ? "Back under the notch" : "Float: move it anywhere") {
                studio.floating.toggle()
            }
            PrompterButton(symbol: "xmark", help: "Close the prompter") { studio.stopPrompting() }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .padding(.top, 18)
        // A dark band behind them, so they don't sit on the text.
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85), .black], startPoint: .top, endPoint: .bottom))
    }
}

/// Studio's colour (user's ask, 2026-11-01): quicksilver blue, the Studio tab's own blue
/// (`NotchPalette.windowsBlue` and its holo stops) with a liquid-metal shine. The prompter's
/// ring, Studio's Mirror / Prompter switch, the cue being read.
enum Quicksilver {
    static let core = Color(hex: 0xB5DDF0)    // the bright highlight (the tab's lightest stop)
    static let bright = Color(hex: 0x5FA3DA)
    static let royal = Color(hex: 0x3A86C8)   // the Studio tab's blue
    static let deep = Color(hex: 0x1F4FA0)    // the edges (its darkest stop)
    /// The Studio blue at full strength, for glows that blur (blurring dulls a colour).
    static let vivid = Color(hex: 0x2F7BF0)
    /// For a button or pill: royal blue with a metallic top light.
    static let fill = LinearGradient(colors: [bright, royal, deep], startPoint: .top, endPoint: .bottom)
}

/// The voice ring, after Moody's (user's ask, 2026-11-01: "moody has its own softer [look],
/// respect it"; built afresh): a thick ring of light, heavily blurred, its top arc rising from
/// the prompter's bottom edge with a dark centre, in the Studio blue. It swells and brightens
/// gently with the voice and settles when you stop — no hard rim, nothing popping.
/// `level` 0…1 (the voice, smoothed slowly).
struct QuicksilverRing: View {
    let level: Double
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { box in
            // 30 frames a second, flattened into one layer: big blurs redrawn at 120 Hz took the
            // graphics chip from Whisper, and a transcription took 7 s (live test, 2026-11-01).
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // A slow breath underneath, so it's alive even between words.
                let breath = reduceMotion ? 0 : (sin(t * 1.3) + 1) / 2
                let energy = min(1, level + breath * 0.05)
                let diameter = box.size.width * (0.42 + energy * 0.16)
                let thickness = diameter * (0.07 + energy * 0.05)
                // Saturated Studio blues only: the whitish highlight greyed it under the blur.
                let light = LinearGradient(colors: [Quicksilver.bright, Quicksilver.royal, Quicksilver.deep],
                                           startPoint: .top, endPoint: .bottom)
                ZStack {
                    // The wide glow round it.
                    Circle()
                        .stroke(Quicksilver.vivid, lineWidth: thickness * 2.6)
                        .blur(radius: thickness * 1.6)
                        .opacity(0.35 + energy * 0.4)
                    // The ring itself: thick and soft.
                    Circle()
                        .stroke(light, lineWidth: thickness)
                        .blur(radius: thickness * 0.55)
                        .opacity(0.45 + energy * 0.55)
                }
                .frame(width: diameter, height: diameter)
                .padding(thickness * 4)
                .drawingGroup()
                .padding(-thickness * 4)
                // Its top arc shows above the bottom edge, rising a little as you speak.
                .position(x: box.size.width / 2, y: box.size.height + diameter / 2 - diameter * (0.2 + energy * 0.08))
            }
        }
    }
}

/// Free resizing (user's ask, 2026-11-01: the corner icon was "so restrictive"): every edge
/// and corner drags, at any time, with the matching pointer — left or right for width (it
/// stays centred under the camera, so both sides move), bottom for height, the bottom
/// corners for both — from a sliver up to nearly the whole screen. Tracked in screen points,
/// since the window moves as it resizes.
private struct ResizeEdges: View {
    @Bindable var studio: StudioModel
    @State private var start: (mouse: NSPoint, size: CGSize)?

    private enum Edge { case left, right, bottom, bottomLeft, bottomRight }
    private static let grip: CGFloat = 8

    var body: some View {
        ZStack {
            handle(.left).frame(width: Self.grip).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 30)
            handle(.right).frame(width: Self.grip).frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 30)
            handle(.bottom).frame(height: Self.grip).frame(maxHeight: .infinity, alignment: .bottom).padding(.horizontal, 16)
            handle(.bottomLeft).frame(width: 16, height: 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            handle(.bottomRight).frame(width: 16, height: 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private func handle(_ edge: Edge) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { cursor(edge).push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { _ in
                let mouse = NSEvent.mouseLocation
                let begin = start ?? (mouse, studio.size)
                start = begin
                let dx = mouse.x - begin.mouse.x, dy = begin.mouse.y - mouse.y  // down is taller
                var size = begin.size
                switch edge {
                case .left: size.width -= dx * 2
                case .right: size.width += dx * 2
                case .bottom: size.height += dy
                case .bottomLeft: size.width -= dx * 2; size.height += dy
                case .bottomRight: size.width += dx * 2; size.height += dy
                }
                let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }?.frame ?? NSScreen.main?.frame ?? .zero
                size.width = min(max(200, size.width), max(200, screen.width - 40))
                size.height = min(max(60, size.height), max(60, screen.height * 0.85))
                studio.size = size
                PrompterController.shared.resize(to: size)
            }.onEnded { _ in start = nil })
    }

    private func cursor(_ edge: Edge) -> NSCursor {
        switch edge {
        case .left, .right: .resizeLeftRight
        case .bottom: .resizeUpDown
        case .bottomLeft, .bottomRight: .crosshair
        }
    }
}

/// The cues, hanging under the prompter: numbered, the one being read marked in quicksilver
/// blue; a click jumps there and folds the list.
private struct CueList: View {
    @Bindable var studio: StudioModel
    @State private var hovered: Int?

    var body: some View {
        let cues = studio.script.cues
        let current = studio.script.cue(atLine: studio.readingLine)
        let rows = VStack(spacing: 2) {
            ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                let chosen = cue == current
                Button { studio.goTo(cue) } label: {
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(chosen ? Color.black.opacity(0.55) : MoodyLook.quiet)
                            .frame(width: 18, alignment: .trailing)
                        Text(cue.title).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(chosen ? Color.black : MoodyLook.cream).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(chosen ? MoodyLook.cream : hovered == index ? MoodyLook.row : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
            }
        }
        .padding(6)
        // Up to six, no scroll view: in the notch (no focus of its own) a scroll view swallowed
        // the first click, and cues couldn't be picked (user's report, 2026-11-01).
        Group {
            if cues.count <= 6 { rows } else { ScrollView(.vertical, showsIndicators: false) { rows } }
        }
        .frame(height: PrompterController.cueListHeight(cues.count))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MoodyLook.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .onHover { if $0 { ShelfDrop.focusNotch() } }
    }
}

private struct PrompterButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            .buttonStyle(PrompterButtonStyle())
            .help(help)
            .accessibilityLabel(help)
    }
}

/// The prompter's black and white (user's ask, 2026-11-01: "white and black like Moody", from
/// its site): dark slate circles with white icons; a chosen cue, or a button that's on, inverted
/// to cream with black; a charcoal cue list in a monospaced face.
enum MoodyLook {
    static let slate = Color(red: 0.16, green: 0.19, blue: 0.21)
    static let slatePressed = Color(red: 0.24, green: 0.28, blue: 0.31)
    static let card = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let row = Color.white.opacity(0.09)
    static let cream = Color(red: 0.95, green: 0.93, blue: 0.87)
    static let quiet = Color.white.opacity(0.45)
}

private struct PrompterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(MoodyLook.cream)
            .frame(width: 26, height: 26)
            .background(Circle().fill(configuration.isPressed ? MoodyLook.slatePressed : MoodyLook.slate))
            .contentShape(Circle())
    }
}

/// Under the prompter: ⌃ previous cue, "2 / 7" (opens and closes the list), ⌄ next cue.
struct CueBar: View {
    @Bindable var studio: StudioModel
    static let height: CGFloat = 30

    var body: some View {
        let cues = studio.script.cues
        let current = studio.script.cue(atLine: studio.readingLine).flatMap { cues.firstIndex(of: $0) } ?? 0
        HStack(spacing: 4) {
            Button { studio.nextCue(-1) } label: { Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(CueBarButton()).disabled(current == 0).help("Previous cue (⌃⌘↑)")
            Button { studio.cuesOpen.toggle() } label: {
                HStack(spacing: 4) {
                    Text("\(current + 1)/\(cues.count)").font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    Image(systemName: studio.cuesOpen ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .bold))
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(CueBarButton(wide: true, on: studio.cuesOpen)).help(studio.cuesOpen ? "Close the cues" : "All cues")
            Button { studio.nextCue(1) } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(CueBarButton()).disabled(current >= cues.count - 1).help("Next cue (⌃⌘↓)")
        }
        .padding(3)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .frame(height: Self.height)
        .onHover { if $0 { ShelfDrop.focusNotch() } }  // the first click lands (the notch takes no focus by itself)
    }
}

private struct CueBarButton: ButtonStyle {
    var wide = false
    var on = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(on ? Color.black : MoodyLook.cream.opacity(enabled ? 1 : 0.3))
            .frame(minWidth: wide ? 52 : 24, minHeight: 24)
            .background(Capsule().fill(on ? MoodyLook.cream : configuration.isPressed ? MoodyLook.slatePressed : MoodyLook.slate))
            .contentShape(Capsule())
    }
}

private struct LineTops: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue()) { $1 } }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
