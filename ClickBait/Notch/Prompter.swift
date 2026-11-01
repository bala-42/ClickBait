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

    /// Top-centred on the screen with the notch (the camera), else the main screen.
    private func place(_ panel: NSPanel, size: CGSize? = nil) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let size = size ?? StudioModel.shared.size
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

    /// The script's lines with where each starts, so a cue can jump to its line.
    private var lines: [(start: Int, text: String)] {
        var start = 0
        return studio.script.readable.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            defer { start += line.count + 1 }
            return (start, String(line))
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Self.shape.fill(Color.black)
            QuicksilverArc(level: studio.playing ? 0.35 : 0.18, reduceMotion: reduceMotion)
                .frame(width: studio.size.width * 0.8, height: 70)
                .offset(y: 34)
                .clipShape(Self.shape)
                .allowsHitTesting(false)
            text
            if hovering { controls.transition(.opacity) }
        }
        .frame(width: studio.size.width, height: studio.size.height)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .onChange(of: studio.jump) { _, target in
            guard let target else { return }
            let start = lines.last(where: { $0.start <= target })?.start ?? 0
            withAnimation(.easeInOut(duration: 0.35)) { studio.offset = max(0, (lineTops[start] ?? 0) - 4) }
            studio.jump = nil
        }
        .onChange(of: studio.playing) { _, _ in lastTick = nil }
    }

    /// The script, scrolling up; lines fade in at the bottom and out under the notch.
    private var text: some View {
        TimelineView(.animation(paused: !studio.playing)) { timeline in
            VStack(alignment: .center, spacing: 6) {
                ForEach(lines, id: \.start) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: studio.fontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: LineTops.self, value: [line.start: proxy.frame(in: .named("script")).minY])
                        })
                }
            }
            .padding(.horizontal, 24)
            .background(GeometryReader { proxy in Color.clear.preference(key: ContentHeight.self, value: proxy.size.height) })
            .coordinateSpace(name: "script")
            .offset(y: -studio.offset)
            .onChange(of: timeline.date) { _, now in advance(to: now) }
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
        guard studio.playing, let last = lastTick else { return }
        nudge(by: studio.speed * now.timeIntervalSince(last))
        if studio.offset >= max(0, contentHeight - 20) { studio.playing = false }  // the end
    }

    private func nudge(by points: Double) {
        studio.scroll(by: points)
    }

    /// On hover: play or pause, slower and faster, the cues, text size, close; and the
    /// bottom-right corner resizes.
    private var controls: some View {
        HStack(spacing: 6) {
            PrompterButton(symbol: studio.playing ? "pause.fill" : "play.fill", help: studio.playing ? "Pause" : "Scroll") {
                studio.playing.toggle()
            }
            PrompterButton(symbol: "tortoise.fill", help: "Slower") { studio.speed = max(6, studio.speed - 6) }
            PrompterButton(symbol: "hare.fill", help: "Faster") { studio.speed = min(120, studio.speed + 6) }
            if !studio.script.cues.isEmpty {
                Menu {
                    ForEach(studio.script.cues) { cue in Button(cue.title) { studio.goTo(cue) } }
                } label: {
                    Image(systemName: "list.bullet").font(.system(size: 10, weight: .bold))
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(PrompterButtonStyle()).fixedSize()
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
    }
}

/// The voice glow, in quicksilver (user's ask, 2026-11-01: like Moody's ring, in liquid metal
/// rather than royal blue): a white core, silver, cool steel at the edges, with a highlight
/// sliding across it. `level` 0…1 (resting, or the voice's loudness with voice-following).
struct QuicksilverArc: View {
    let level: Double
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let sweep = reduceMotion ? 0.5 : (sin(t * (0.6 + level * 2)) + 1) / 2
            // Fades to nothing at its own edge, so no rim shows even unblurred.
            let glow = EllipticalGradient(stops: [.init(color: Color(white: 1, opacity: 0.95), location: 0),
                                                  .init(color: Color(red: 0.78, green: 0.8, blue: 0.84, opacity: 0.8), location: 0.3),
                                                  .init(color: Color(red: 0.42, green: 0.46, blue: 0.53, opacity: 0.45), location: 0.6),
                                                  .init(color: .clear, location: 1)],
                                          center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
            Ellipse()
                .fill(glow)
                .overlay(
                    Ellipse().fill(LinearGradient(stops: [.init(color: .clear, location: max(0, sweep - 0.18)),
                                                          .init(color: .white.opacity(0.7), location: sweep),
                                                          .init(color: .clear, location: min(1, sweep + 0.18))],
                                                  startPoint: .leading, endPoint: .trailing))
                        .mask(Ellipse().fill(EllipticalGradient(colors: [.white, .clear], center: .center, endRadiusFraction: 0.5)))
                        .blendMode(.screen)
                )
                .scaleEffect(x: 1, y: 0.6 + level * 0.8, anchor: .bottom)
                .blur(radius: 14)
                .opacity(0.25 + level * 0.75)
        }
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
