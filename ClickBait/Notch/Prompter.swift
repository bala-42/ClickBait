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

    /// New size from a corner drag: still centred under the notch.
    func resize(to size: CGSize) {
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
        CGFloat(min(max(cues, 1), 6)) * 30 + 44
    }

    /// Top-centred on the screen with the notch (the camera), else the main screen; taller
    /// by the cue list when it hangs open below.
    private func place(_ panel: NSPanel, size: CGSize? = nil) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let studio = StudioModel.shared
        var size = size ?? studio.size
        if studio.cuesOpen { size.height += 8 + Self.cueListHeight(studio.script.cues.count) }
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    /// The notch's height on that screen: where the text can start without hiding behind it.
    static var notchHeight: CGFloat {
        (NSScreen.screens.first { $0.safeAreaInsets.top > 0 }?.safeAreaInsets.top).map { $0 } ?? 0
    }
}

struct PrompterView: View {
    @Bindable var studio: StudioModel
    @State private var hovering = false
    @State private var lineTops: [Int: CGFloat] = [:]
    @State private var contentHeight: CGFloat = 0
    @State private var dragStart: CGSize?
    @State private var lastTick: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let top = max(PrompterController.notchHeight, 10) + 8
    private static let shape = UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)

    /// The script's lines, numbered: cues and the voice's place meet them by line.
    private var lines: [(index: Int, text: String)] {
        studio.script.readable.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { ($0.offset, String($0.element)) }
    }

    var body: some View {
        VStack(spacing: 8) {
            prompter
            if studio.cuesOpen {
                CueList(studio: studio)
                    .frame(width: min(studio.size.width, 420))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: studio.size.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: studio.cuesOpen)
    }

    private var prompter: some View {
        ZStack(alignment: .bottom) {
            Self.shape.fill(Color.black)
            QuicksilverRing(level: max(studio.level, studio.playing ? 0.25 : 0.1), reduceMotion: reduceMotion)
                .frame(width: studio.size.width, height: studio.size.height)
                .clipShape(Self.shape)
                .allowsHitTesting(false)
            text
            if hovering || studio.cuesOpen { controls.transition(.opacity) }
        }
        .frame(width: studio.size.width, height: studio.size.height)
        .clipShape(Self.shape)  // the controls' dark band keeps the rounded corners
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
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
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: studio.fontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
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
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                     .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func advance(to now: Date) {
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let elapsed = now.timeIntervalSince(last)
        if studio.following {
            // Glide to the voice's place: its line, as far through it as you are, kept a
            // quarter of the way down; still when there's no new place (you stopped).
            guard let place = studio.place, let top = lineTops[place.line] else { return }
            let bottom = lineTops[place.line + 1] ?? contentHeight
            let target = max(0, top + (bottom - top) * place.fraction - (studio.size.height - self.top) * 0.35)
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
            // Follow my voice (on from the start), or ▶ at a set speed.
            Button {
                if studio.following { studio.stopFollowing() } else { studio.startFollowing() }
            } label: {
                Image(systemName: studio.following ? "waveform" : "mic.fill").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white).frame(width: 24, height: 24)
                    .background(Circle().fill(studio.following ? AnyShapeStyle(Quicksilver.fill) : AnyShapeStyle(Color.white.opacity(0.14))))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(studio.following ? "Following your voice: click to stop" : "Follow my voice")
            .accessibilityLabel(studio.following ? "Stop following my voice" : "Follow my voice")
            PrompterButton(symbol: studio.playing ? "pause.fill" : "play.fill", help: studio.playing ? "Pause" : "Scroll at a set speed") {
                if studio.following { studio.stopFollowing() }
                studio.playing.toggle()
            }
            PrompterButton(symbol: "tortoise.fill", help: "Slower") { studio.speed = max(6, studio.speed - 6) }
            PrompterButton(symbol: "hare.fill", help: "Faster") { studio.speed = min(120, studio.speed + 6) }
            if !studio.script.cues.isEmpty {
                // The cue list hangs below the prompter (like Moody's), not a menu.
                Button { studio.cuesOpen.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet").font(.system(size: 10, weight: .bold))
                        Text("Cues").font(.system(size: 11, weight: .semibold))
                        Image(systemName: studio.cuesOpen ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(studio.cuesOpen ? AnyShapeStyle(Quicksilver.fill) : AnyShapeStyle(Color.white.opacity(0.14))))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Jump to a cue")
            }
            PrompterButton(symbol: "textformat.size.smaller", help: "Smaller text") { studio.fontSize = max(14, studio.fontSize - 2) }
            PrompterButton(symbol: "textformat.size.larger", help: "Bigger text") { studio.fontSize = min(44, studio.fontSize + 2) }
            Spacer()
            PrompterButton(symbol: "xmark", help: "Close the prompter") { studio.stopPrompting() }
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .global).onChanged { drag in
                    let start = dragStart ?? studio.size
                    dragStart = start
                    // Centred under the notch: a corner drag grows both sides.
                    let size = CGSize(width: min(1000, max(340, start.width + drag.translation.width * 2)),
                                      height: min(460, max(110, start.height + drag.translation.height)))
                    studio.size = size
                    PrompterController.shared.resize(to: size)
                }.onEnded { _ in dragStart = nil })
                .help("Drag to resize")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .padding(.top, 18)
        // A dark band behind them, so they don't sit on the text.
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85), .black], startPoint: .top, endPoint: .bottom))
    }
}

/// Studio's colour (user's ask, 2026-11-01): quicksilver blue, a vibrant royal-blue gradient
/// with a liquid-metal shine. The prompter's glow and Studio's Mirror / Prompter switch.
enum Quicksilver {
    static let core = Color(red: 0.80, green: 0.86, blue: 1.0)      // the bright, nearly white highlight
    static let bright = Color(red: 0.30, green: 0.47, blue: 1.0)    // vibrant royal blue
    static let royal = Color(red: 0.15, green: 0.27, blue: 0.92)
    static let deep = Color(red: 0.07, green: 0.12, blue: 0.55)     // the edges
    /// For a button or pill: royal blue with a metallic top light.
    static let fill = LinearGradient(colors: [bright, royal, deep], startPoint: .top, endPoint: .bottom)
}

/// The voice ring, in quicksilver blue (user's ask, 2026-11-01: "the same ring thing that
/// Moody has", not a plain gradient; built afresh): a ring of light whose top arc rises from
/// the prompter's bottom edge — a wide soft halo, a bright rim, a faint inner wash — with a
/// metallic highlight running round it. `level` 0…1: resting, or the voice's loudness; the
/// ring swells, brightens and its shine runs faster as you speak.
struct QuicksilverRing: View {
    let level: Double
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { box in
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let spin = reduceMotion ? 0 : t * (25 + level * 140)
                let diameter = box.size.width * 0.62 * (1 + level * 0.12)
                // Bright all round (royal blue at its darkest), with two metallic highlights.
                let rim = AngularGradient(colors: [Quicksilver.royal, Quicksilver.bright, Quicksilver.core, Quicksilver.bright,
                                                   Quicksilver.royal, Quicksilver.bright, Quicksilver.core, Quicksilver.bright,
                                                   Quicksilver.royal],
                                          center: .center, angle: .degrees(spin))
                ZStack {
                    // The inner wash: the ring lights what's inside it.
                    Circle().fill(RadialGradient(colors: [.clear, Quicksilver.royal.opacity(0.05 + level * 0.12)],
                                                 center: .center, startRadius: diameter * 0.3, endRadius: diameter * 0.5))
                    // The halo: wide and soft.
                    Circle().stroke(rim, lineWidth: 14 + level * 18).blur(radius: 14 + level * 10).opacity(0.45 + level * 0.4)
                    // The rim: thin and bright.
                    Circle().stroke(rim, lineWidth: 2 + level * 2).blur(radius: 0.5)
                    Circle().stroke(Quicksilver.core.opacity(0.35 + level * 0.4), lineWidth: 0.8)
                }
                .frame(width: diameter, height: diameter)
                // Its top arc shows above the bottom edge, higher as the voice is louder.
                .position(x: box.size.width / 2, y: box.size.height + diameter / 2 - (22 + level * 26))
                .opacity(0.55 + level * 0.45)
            }
        }
    }
}

/// The cues, hanging under the prompter: numbered, the one being read marked in quicksilver
/// blue; a click jumps there and folds the list.
private struct CueList: View {
    @Bindable var studio: StudioModel

    var body: some View {
        let current = studio.script.cue(atLine: studio.readingLine)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Cues").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("\(studio.script.cues.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(studio.script.cues.enumerated()), id: \.element.id) { index, cue in
                        Button { studio.goTo(cue) } label: {
                            HStack(spacing: 10) {
                                Text("\(index + 1)").font(.system(size: 11, weight: .bold).monospacedDigit())
                                    .foregroundStyle(cue == current ? .white : .white.opacity(0.4))
                                    .frame(width: 18, alignment: .trailing)
                                Text(cue.title).font(.system(size: 13, weight: cue == current ? .semibold : .regular))
                                    .foregroundStyle(.white.opacity(cue == current ? 1 : 0.8)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(cue == current ? AnyShapeStyle(Quicksilver.fill.opacity(0.85)) : AnyShapeStyle(Color.clear)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 6)
            }
        }
        .frame(height: PrompterController.cueListHeight(studio.script.cues.count))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
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

private struct PrompterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.3 : 0.14)))
            .contentShape(Circle())
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
