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

private struct SharePickerAnchor: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let host = NSView(frame: .zero)
        DispatchQueue.main.async { view = host }
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if view !== nsView { DispatchQueue.main.async { view = nsView } }
    }
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

// The compact Nook panel follows the supplied NotchNook GIF: black notch, music artwork and
// visualizer while collapsed, then a short rounded panel with Nook/Tray navigation, music,
// shortcut tiles and Mirror when opened.

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

/// The GIF's colours, where the artwork doesn't set them.
enum NotchColors {
    static let artist = Color(red: 0.55, green: 0.62, blue: 0.92)
    static let bar = Color(red: 0.65, green: 0.78, blue: 0.95)
    static let track = Color.white.opacity(0.14)
    static let dim = Color.white.opacity(0.42)
    static let todayCircle = Color(red: 0.18, green: 0.42, blue: 0.92)
    static let todayColumn = Color(red: 0.09, green: 0.14, blue: 0.24)
    static let batteryGreen = Color(red: 0.36, green: 0.82, blue: 0.36)

    /// The artwork's colour, lifted towards white so it reads on black.
    static func lifted(_ color: NSColor?, _ amount: CGFloat, fallback: Color) -> Color {
        guard let base = color?.usingColorSpace(.deviceRGB) else { return fallback }
        return Color(nsColor: base.blended(withFraction: amount, of: .white) ?? base)
    }
}

/// Quiet secondary controls for the notch: charcoal surfaces with a soft Aqua edge on hover.
private struct NotchControlButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .background {
                shape
                    .fill(configuration.isPressed ? NotchColors.bar.opacity(0.16) :
                          hovering ? Color.white.opacity(0.09) : Color.white.opacity(0.045))
            }
            .overlay {
                shape.strokeBorder((hovering || configuration.isPressed)
                                   ? NotchColors.bar.opacity(0.52)
                                   : Color.white.opacity(0.1), lineWidth: 0.8)
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: hovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct NotchView: View {
    let model: NotchController.Model
    let notch: Rect?
    let music: MusicBridge
    let calendar: CalendarSource
    let shelf: ShelfStore
    let settings: AppSettings
    let speech: SpeechModelManager
    let speaker: Speaker
    let searxng: SearXNGStatus
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    let onDragIn: () -> Void
    let onTabChange: (NotchController.Model.Tab) -> Void
    let onCollapse: () -> Void

    @Namespace private var art
    @State private var showingMirror = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open = model.state == .expanded
        let look = NotchPanel.shape(model.state, notch: notch, activity: model.activity,
                                    hovering: model.hovering && !open, hud: model.hud != nil,
                                    shelf: model.tab == .shelf, settings: model.tab == .settings)
        let ear = CGFloat(NotchPanel.ear)
        let shape = NotchShape(ear: ear, bottom: CGFloat(look.radius))
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            Group {
                if open {
                    if showingMirror {
                        CameraMirrorPanel { showingMirror = false }
                            .transition(.opacity)
                    } else if model.tab == .settings {
                        SettingsView(settings: settings, speech: speech, speaker: speaker,
                                     searxng: searxng,
                                     returnLabel: model.settingsReturnTab == .shelf ? "Back to Tray" : "Back to Nook",
                                     onBack: { onTabChange(model.settingsReturnTab) }, onCollapse: onCollapse)
                            .transition(.opacity.combined(with: .scale(scale: 0.99, anchor: .top)))
                    } else {
                        OpenNotch(model: model, music: music, calendar: calendar, shelf: shelf, art: art,
                                  onTabChange: onTabChange, onMirror: { showingMirror = true })
                            .transition(.opacity.combined(with: .scale(scale: 0.99, anchor: .top)))
                    }
                } else if let hud = model.hud {
                    HUDWings(level: hud.level, muted: hud.muted)
                } else if model.activity {
                    ActivityWings(music: music, art: art)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, ear)
        }
        .frame(width: CGFloat(look.width) + 2 * ear, height: CGFloat(look.height))
        .contentShape(shape)
        .dropDestination(for: URL.self) { _, _ in false } isTargeted: { if $0, !open { onDragIn() } }
        .onHover(perform: onHover)
        .onTapGesture { if !open { onTap() } }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : spring(open: open), value: open)
        .animation(reduceMotion ? nil : spring(open: true), value: model.tab)
        .animation(reduceMotion ? nil : spring(open: true), value: look.width)
        .animation(reduceMotion ? nil : spring(open: true), value: look.height)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: model.hovering)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: model.activity)
        .accessibilityElement(children: open ? .contain : .ignore)
        .accessibilityLabel(open ? "ClickBait notch" : model.activity ? "Now playing: \(music.title)" : "ClickBait notch, closed")
        .accessibilityHint(open ? "" : "Rest the pointer here, or click, to open")
        .accessibilityAddTraits(open ? [] : .isButton)
    }

    private func spring(open: Bool) -> Animation {
        let s = open ? NotchPanel.openSpring : NotchPanel.closeSpring
        return .spring(response: s.response, dampingFraction: s.damping)
    }
}

// MARK: - Closed, music playing

/// The artwork on the left wing, a visualizer on the right (GIF 1.6 s on).
private struct ActivityWings: View {
    let music: MusicBridge
    let art: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            Artwork(music: music, corner: 5)
                .matchedGeometryEffect(id: "art", in: art)
                .frame(width: 22, height: 22)
                .padding(.leading, 9)
            Spacer(minLength: 0)
            Visualizer(playing: music.isPlaying, color: NotchColors.lifted(music.tint, 0.45, fallback: NotchColors.artist))
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

/// The volume keys' HUD in the notch's wings: the speaker left, the level right.
private struct HUDWings: View {
    let level: Double
    let muted: Bool

    var body: some View {
        let symbol = muted ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        HStack(spacing: 0) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: NotchPanel.hudWing)
            Spacer(minLength: 0)
            ZStack(alignment: .leading) {
                Capsule().fill(NotchColors.track)
                Capsule().fill(NotchColors.bar).frame(width: max(4, 60 * level))
            }
            .frame(width: 60, height: 4)
            .frame(width: NotchPanel.hudWing)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(muted ? "Volume muted" : "Volume \(Int((level * 100).rounded())) percent")
    }
}

// MARK: - Open

private struct OpenNotch: View {
    let model: NotchController.Model
    let music: MusicBridge
    let calendar: CalendarSource
    let shelf: ShelfStore
    let art: Namespace.ID
    let onTabChange: (NotchController.Model.Tab) -> Void
    let onMirror: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                switch model.tab {
                case .home: home.transition(.opacity)
                case .shelf: ShelfView(shelf: shelf, note: model.note).transition(.opacity)
                case .settings: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Nook and Tray at left, settings and battery at right, like the GIF.
    private var header: some View {
        HStack(spacing: 0) {
            tab(.home, symbol: "sparkle", label: "Nook")
            tab(.shelf, symbol: "tray.fill", label: "Tray").padding(.leading, 8)
            Spacer(minLength: 18)
            Button { onTabChange(.settings) } label: {
                Image(systemName: "gearshape.circle").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("ClickBait settings")
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .frame(height: CGFloat(model.notch?.height ?? 30))
    }

    private func tab(_ tab: NotchController.Model.Tab, symbol: String, label: String) -> some View {
        Button { onTabChange(tab) } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(model.tab == tab ? Color.white : NotchColors.dim)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(model.tab == tab ? Color.white.opacity(0.12) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
    }

    /// The GIF's compact row: music, two app tiles, and Mirror.
    private var home: some View {
        HStack(spacing: 11) {
            NookMusic(music: music, art: art)
                .frame(width: 226, height: 94, alignment: .leading)
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 92)
            VStack(spacing: 8) {
                NookAppTile(title: "Spotify", symbol: "sparkles", bundleID: "com.spotify.client")
                NookAppTile(title: "Music", symbol: "sparkles", bundleID: "com.apple.Music")
            }
            .frame(width: 111)
            MirrorTile(onTap: onMirror)
                .frame(width: 76, height: 76)
        }
        .padding(.horizontal, 15)
        .padding(.top, 10)
        .padding(.bottom, 9)
    }
}

private struct NookMusic: View {
    let music: MusicBridge
    let art: Namespace.ID

    var body: some View {
        HStack(spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                Artwork(music: music, corner: 9)
                    .matchedGeometryEffect(id: "art", in: art)
                    .frame(width: 78, height: 78)
                if let player = music.player { PlayerBadge(player: player).offset(x: 4, y: 4) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(music.hasTrack ? music.title : "Nothing playing")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Text(music.hasTrack ? music.artist : "Music or Spotify")
                    .font(.system(size: 10)).foregroundStyle(NotchColors.lifted(music.tint, 0.45, fallback: NotchColors.artist)).lineLimit(1)
                HStack(spacing: 15) {
                    nookControl("backward.end.fill", label: "Previous track") { music.send("previous track") }
                    nookControl(music.isPlaying ? "pause.fill" : "play.fill", label: music.isPlaying ? "Pause" : "Play") { music.send("playpause") }
                    nookControl("forward.end.fill", label: "Next track") { music.send("next track") }
                }
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func nookControl(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct NookAppTile: View {
    let title: String
    let symbol: String
    let bundleID: String

    var body: some View {
        Button {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(NotchColors.bar)
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(NotchControlButtonStyle())
        .accessibilityLabel("Open \(title)")
    }
}

private struct MirrorTile: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(NotchColors.bar)
                Text("Mirror").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(NotchControlButtonStyle())
        .help("Show the front camera in the notch")
        .accessibilityLabel("Mirror. Show the front camera in the notch")
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

    @Published private(set) var state: State = .starting
    let session = AVCaptureSession()
    private var configured = false

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
            session.commitConfiguration()
            configured = true
            session.startRunning()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
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
        view.previewLayer.connection?.isVideoMirrored = true
        return view
    }

    func updateNSView(_ view: CameraPreviewHost, context: Context) {
        view.previewLayer.session = session
        view.previewLayer.connection?.isVideoMirrored = true
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

private struct CameraMirrorPanel: View {
    @StateObject private var camera = CameraMirrorModel()
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black
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
            VStack {
                HStack {
                    Text("Mirror").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17)).foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close mirror")
                }
                .padding(.horizontal, 13).padding(.top, 8)
                Spacer()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
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

private struct NowPlaying: View {
    let music: MusicBridge
    @State private var dragging: Double?

    var body: some View {
        let tint = NotchColors.lifted(music.tint, 0.45, fallback: NotchColors.artist)
        VStack(alignment: .leading, spacing: 0) {
            Text(music.title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            Text(music.artist).font(.system(size: 13)).foregroundStyle(tint).lineLimit(1)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let at = dragging ?? music.currentPosition(at: context.date)
                let fraction = music.duration > 0 ? at / music.duration : 0
                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(NotchColors.track)
                            Capsule().fill(NotchColors.lifted(music.tint, 0.6, fallback: NotchColors.bar))
                                .frame(width: max(4, geometry.size.width * fraction))
                        }
                        .frame(height: 4)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { dragging = TrackTime.position(x: $0.location.x, width: geometry.size.width, duration: music.duration) }
                            .onEnded { _ in if let to = dragging { music.seek(to: to) }; dragging = nil })
                    }
                    .frame(height: 12)
                    HStack {
                        Text(TrackTime.text(at))
                        Spacer()
                        Text(TrackTime.text(music.duration))
                    }
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(tint.opacity(0.85))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(TrackTime.text(at)) of \(TrackTime.text(music.duration))")
                .accessibilityAdjustableAction { direction in
                    let step = direction == .increment ? 10.0 : -10.0
                    music.seek(to: min(max(at + step, 0), music.duration))
                }
            }
            .padding(.top, 9)
            HStack(spacing: 28) {
                control("backward.fill", size: 15, label: "Previous track") { music.send("previous track") }
                control(music.isPlaying ? "pause.fill" : "play.fill", size: 25, label: music.isPlaying ? "Pause" : "Play") {
                    music.send("playpause")
                }
                control("forward.fill", size: 15, label: "Next track") { music.send("next track") }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 1)
            if let error = music.error {
                Text(error).font(.system(size: 10)).foregroundStyle(NotchColors.dim).lineLimit(2).padding(.top, 2)
            }
        }
    }

    private func control(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .bold)).foregroundStyle(.white).frame(height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct NothingPlaying: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.07))
                .overlay(Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(NotchColors.dim))
                .frame(width: 101, height: 101)
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing playing").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Text("Play something in Music or Spotify").font(.system(size: 12)).foregroundStyle(NotchColors.dim)
            }
        }
        .accessibilityElement(children: .combine)
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
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Color.white.opacity(0.1)).overlay(Image(systemName: "music.note").foregroundStyle(NotchColors.dim))
            }
        }
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

/// The player's own icon in a small circle on the artwork's corner.
private struct PlayerBadge: View {
    let player: MusicBridge.Player

    var body: some View {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable()
                .frame(width: 24, height: 24)
                .accessibilityLabel(player.name)
        }
    }
}

/// The battery's gauge: green fill, a white bolt while charging.
private struct BatteryGauge: View {
    let level: Double
    let charging: Bool

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5).strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2).fill(level < 0.2 && !charging ? Color.red : NotchColors.batteryGreen)
                    .frame(width: max(3, 21 * level)).padding(2)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 8, weight: .black)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 25, height: 12)
            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.5)).frame(width: 1.5, height: 4)
        }
    }
}

// MARK: - The week

/// "Aug 2025", six days with today third in a blue circle on a dark column, and today's events
/// (or "No events today · Enjoy your free time!") under them.
private struct WeekView: View {
    let calendar: CalendarSource
    @State private var selectedDate = Date()

    private var systemCalendar: Calendar { .current }
    private var monthDays: [Date] { CalendarNavigation.monthDays(containing: selectedDate, calendar: systemCalendar) }
    private var leadingDays: Int {
        guard let first = monthDays.first else { return 0 }
        return (systemCalendar.component(.weekday, from: first) - systemCalendar.firstWeekday + 7) % 7
    }
    private var monthTitle: String { selectedDate.formatted(.dateTime.month(.wide)) }
    private var selectedYear: Int { systemCalendar.component(.year, from: selectedDate) }
    private var selectedMonth: Int { systemCalendar.component(.month, from: selectedDate) }
    private var monthNames: [String] { (1...12).compactMap { DateComponents(calendar: systemCalendar, year: selectedYear, month: $0, day: 1).date?.formatted(.dateTime.month(.wide)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month")
                Menu {
                    ForEach(1...12, id: \.self) { month in
                        Button(monthNames[month - 1]) { choose(year: selectedYear, month: month) }
                    }
                } label: {
                    Text(monthTitle).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Choose month, currently \(monthTitle)")
                Menu {
                    ForEach((selectedYear - 8)...(selectedYear + 8), id: \.self) { year in
                        Button(String(year)) { choose(year: year, month: selectedMonth) }
                    }
                } label: {
                    Text(String(selectedYear)).font(.system(size: 17)).foregroundStyle(NotchColors.dim)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Choose year, currently \(selectedYear)")
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month")
                Spacer(minLength: 4)
                Button("Today") { selectedDate = CalendarNavigation.today() }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchColors.bar)
                    .buttonStyle(.plain)
            }
            .buttonStyle(.plain)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(weekdaySymbols, id: \.self) { weekday in
                    Text(weekday).font(.system(size: 10, weight: .medium)).foregroundStyle(NotchColors.dim)
                        .frame(maxWidth: .infinity, minHeight: 15)
                }
                ForEach(0..<(leadingDays + monthDays.count), id: \.self) { index in
                    if index < leadingDays {
                        Color.clear.frame(height: 31)
                    } else {
                        let date = monthDays[index - leadingDays]
                        dayButton(date)
                    }
                }
            }
            .accessibilityLabel("\(monthTitle) \(selectedYear)")

            HStack(spacing: 6) {
                Text(selectedDate.formatted(date: .complete, time: .omitted))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                if !calendar.eventsAllowed && !calendar.remindersAllowed {
                    Text("Events and reminders unavailable").font(.system(size: 10)).foregroundStyle(NotchColors.dim)
                } else if !calendar.eventsAllowed || !calendar.remindersAllowed {
                    HStack(spacing: 5) {
                        Text(!calendar.eventsAllowed ? "Events unavailable" : "Reminders unavailable")
                            .font(.system(size: 10)).foregroundStyle(NotchColors.dim)
                        Button(calendar.permissionDenied ? "Settings" : "Enable") { calendar.requestAccess() }
                            .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(NotchColors.bar)
                    }
                }
            }
            agenda
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 13)
        .padding(.trailing, 16)
        .frame(width: 380)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .onAppear { calendar.refresh(for: selectedDate) }
        .onChange(of: selectedDate) { _, value in calendar.refresh(for: value) }
    }

    private var weekdaySymbols: [String] {
        let symbols = systemCalendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(systemCalendar.firstWeekday - 1 + $0) % symbols.count] }
    }

    private func dayButton(_ date: Date) -> some View {
        let today = CalendarNavigation.isSameDay(date, Date(), calendar: systemCalendar)
        let selected = CalendarNavigation.isSameDay(date, selectedDate, calendar: systemCalendar)
        return Button { selectedDate = date } label: {
            Text(String(systemCalendar.component(.day, from: date)))
                .font(.system(size: 12, weight: selected || today ? .semibold : .regular))
                .foregroundStyle(selected || today ? .white : Color.white.opacity(0.78))
                .frame(maxWidth: .infinity, minHeight: 31)
                .background {
                    if today { Circle().fill(NotchColors.todayCircle).frame(width: 27, height: 27) }
                }
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: 9).strokeBorder(NotchColors.bar, lineWidth: 1.5).padding(1) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var agenda: some View {
        if !calendar.eventsAllowed && !calendar.remindersAllowed {
            VStack(spacing: 5) {
                Text(calendar.permissionDenied
                     ? "Enable Calendar and Reminders in System Settings to show this date's agenda."
                     : "Allow access to show events and reminders for this date.")
                    .font(.system(size: 11)).foregroundStyle(NotchColors.dim)
                Button(calendar.permissionDenied ? "Open System Settings" : "Allow Calendar and Reminders access",
                       action: calendar.requestAccess)
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(NotchColors.bar)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if calendar.isLoading {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Loading agenda…").font(.system(size: 11)).foregroundStyle(NotchColors.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let error = calendar.error {
            Text(error).font(.system(size: 11)).foregroundStyle(NotchColors.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 5) {
                    if calendar.events.isEmpty && calendar.reminders.isEmpty {
                        Text("Nothing scheduled for this date.")
                            .font(.system(size: 11)).foregroundStyle(NotchColors.dim).padding(.top, 3)
                    }
                    ForEach(calendar.events) { event in
                        agendaRow(title: event.title, detail: eventDetail(event), color: event.color, symbol: "calendar")
                    }
                    ForEach(calendar.reminders.filter { $0.dueDate != nil }) { reminder in
                        agendaRow(title: reminder.title,
                                  detail: reminder.hasDueTime ? reminder.dueDate!.formatted(date: .omitted, time: .shortened) : "Due today",
                                  color: NotchColors.bar, symbol: "checkmark.circle")
                    }
                    let undated = calendar.reminders.filter { $0.dueDate == nil }
                    if !undated.isEmpty {
                        Text("NO DUE DATE").font(.system(size: 9, weight: .semibold)).foregroundStyle(NotchColors.dim)
                            .padding(.top, 4)
                        ForEach(undated) { reminder in
                            agendaRow(title: reminder.title, detail: "Anytime", color: NotchColors.bar, symbol: "checkmark.circle")
                        }
                    }
                }
                .padding(.trailing, 3)
            }
            .scrollIndicators(.visible)
        }
    }

    private func agendaRow(title: String, detail: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 5)
            Text(detail).font(.system(size: 10)).foregroundStyle(NotchColors.dim).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func eventDetail(_ event: CalendarSource.Event) -> String {
        if event.isAllDay { return "All day" }
        let dayStart = systemCalendar.startOfDay(for: selectedDate)
        let dayEnd = systemCalendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let beginsEarlier = event.start < dayStart
        let endsLater = event.end > dayEnd
        if beginsEarlier && endsLater { return "Continues · until \(formatter.string(from: event.end))" }
        if beginsEarlier { return "Continues" }
        if endsLater { return "\(formatter.string(from: event.start)) · until \(formatter.string(from: event.end))" }
        return formatter.string(from: event.start)
    }

    private func choose(year: Int, month: Int) {
        if let date = CalendarNavigation.date(year: year, month: month,
                                              preservingDay: systemCalendar.component(.day, from: selectedDate),
                                              calendar: systemCalendar) { selectedDate = date }
    }

    private func moveMonth(_ amount: Int) {
        if let date = CalendarNavigation.addingMonths(amount, to: selectedDate, calendar: systemCalendar) { selectedDate = date }
    }
}

// MARK: - Shelf

/// Files dropped here (drag out to use, click to show in Finder) and the quick note.
private struct ShelfView: View {
    let shelf: ShelfStore
    @Bindable var note: NotchController.Note
    @State private var targeted = false
    @State private var sharePickerAnchor: NSView?
    @State private var showingAirDropPanel = false
    @State private var shareError: String?
    @FocusState private var noteFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Files Tray").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("Collect files to share")
                            .font(.system(size: 10)).foregroundStyle(NotchColors.dim)
                    }
                    Spacer()
                    Text("\(shelf.files.count) / 12")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
                HStack(spacing: 7) {
                    if shelf.files.count > 1 {
                        Button(shelf.selectedFiles.count == shelf.files.count ? "Clear selection" : "Select all") {
                            if shelf.selectedFiles.count == shelf.files.count { shelf.clearSelection() }
                            else { shelf.selectAll() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchColors.bar)
                    }
                    Spacer(minLength: 0)
                    if !shelf.selectedFiles.isEmpty {
                        ZStack {
                            Capsule().fill(NotchColors.bar.opacity(0.16))
                            MultiFileDragHandle(urls: shelf.files.filter { shelf.selectedFiles.contains($0) })
                            Label("Drag \(shelf.selectedFiles.count)", systemImage: "hand.draw")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(NotchColors.bar)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .allowsHitTesting(false)
                        }
                        .fixedSize()
                        .accessibilityElement()
                        .accessibilityLabel("Drag \(shelf.selectedFiles.count) selected files together")
                        .accessibilityHint("Drag this control to share the selected files together")
                    }
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(targeted ? 0.065 : 0.025))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(targeted ? NotchColors.bar : Color.white.opacity(0.2),
                                      style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: shelf.files.isEmpty ? [5, 5] : []))
                    if shelf.files.isEmpty {
                        VStack(spacing: 5) {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .font(.system(size: 16, weight: .medium)).foregroundStyle(NotchColors.bar)
                                .frame(width: 34, height: 34).background(NotchColors.bar.opacity(0.13), in: Circle())
                            Text(targeted ? "Release to add files" : "Drop files to collect")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                            Text("Select several, then send them together")
                                .font(.system(size: 9)).foregroundStyle(NotchColors.dim)
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 9) { ForEach(shelf.files, id: \.self) { file($0) } }
                                .padding(.horizontal, 7).padding(.vertical, 4)
                        }
                    }
                }
                .frame(minHeight: 100, maxHeight: .infinity)
                .overlay {
                    if showingAirDropPanel { airDropPanel }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    shelf.add(files)
                    return !files.isEmpty
                } isTargeted: { targeted = $0 }
                .accessibilityLabel(shelf.files.isEmpty ? "Files Tray, empty. Drop files here." : "Files Tray, \(shelf.files.count) files")
            }
            .padding(9)
            .frame(width: 210)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1))

            Button { showingAirDropPanel = true; shareError = nil } label: {
                VStack(spacing: 7) {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(NotchColors.bar)
                    Text("AirDrop").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                    Text(shelf.selectedFiles.isEmpty ? "Select files to send" : "\(shelf.selectedFiles.count) selected")
                        .font(.system(size: 10)).foregroundStyle(NotchColors.dim)
                }
                .frame(width: 145)
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(NotchControlButtonStyle(cornerRadius: 17))
            .help("Review selected files and open the macOS AirDrop picker")
            .accessibilityLabel("AirDrop")
            .accessibilityHint("Opens the in-notch AirDrop panel")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("NOTES", systemImage: "pencil.line")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(NotchColors.dim)
                    Spacer(minLength: 4)
                    Button(action: appendBullet) {
                        Label("Add bullet", systemImage: "list.bullet")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NotchColors.bar)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                    }
                    .buttonStyle(NotchControlButtonStyle())
                    .accessibilityHint("Adds a bullet point at the end of the note")
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $note.text)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .tint(NotchColors.bar)
                        .focused($noteFocused)
                        .accessibilityLabel("Quick note")
                    if note.text.isEmpty {
                        Text("Write a note…")
                            .font(.system(size: 16))
                            .foregroundStyle(NotchColors.dim)
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(14)
            .frame(width: 250)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(noteFocused ? NotchColors.bar.opacity(0.58) : Color.white.opacity(0.08),
                              lineWidth: noteFocused ? 1.1 : 1))
            .animation(.easeOut(duration: 0.14), value: noteFocused)
        }
        .padding(.horizontal, 15)
        .padding(.top, 7)
        .padding(.bottom, 7)
    }

    private func appendBullet() {
        if note.text.isEmpty || note.text.hasSuffix("\n") {
            note.text += "• "
        } else {
            note.text += "\n• "
        }
    }

    private var airDropPanel: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { showingAirDropPanel = false } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(NotchColors.dim)
            .accessibilityLabel("Back to file shelf")

            VStack(alignment: .leading, spacing: 4) {
                Text("AirDrop").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                if shelf.selectedFiles.isEmpty {
                    Text("Select files on the shelf to prepare them for sharing.")
                        .font(.system(size: 10)).foregroundStyle(NotchColors.dim).lineLimit(2)
                } else {
                    Text("\(shelf.selectedFiles.count) selected · choose a recipient in macOS")
                        .font(.system(size: 10)).foregroundStyle(NotchColors.dim).lineLimit(1)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(shelf.files.filter { shelf.selectedFiles.contains($0) }, id: \.self) { url in
                                Text(url.lastPathComponent)
                                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                                    .lineLimit(1).padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.white.opacity(0.09), in: Capsule())
                            }
                        }
                    }
                    .frame(height: 17)
                }
                if let shareError {
                    Text(shareError).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 2)
            Button {
                let urls = shelf.files.filter { shelf.selectedFiles.contains($0) }
                guard !urls.isEmpty else { return }
                guard let sharePickerAnchor else {
                    shareError = "The macOS sharing picker is unavailable here."
                    return
                }
                NSSharingServicePicker(items: urls).show(relativeTo: .zero, of: sharePickerAnchor, preferredEdge: .minY)
            } label: {
                Label("Open picker", systemImage: "arrow.up.right")
            }
            .buttonStyle(AquaButtonStyle())
            .disabled(shelf.selectedFiles.isEmpty)
            .background { SharePickerAnchor(view: $sharePickerAnchor) }
            .accessibilityHint("Opens Apple's sharing picker; choose AirDrop there and select a recipient")
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.97), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(NotchColors.dim.opacity(0.35)))
    }

    private func file(_ url: URL) -> some View {
        let selected = shelf.selectedFiles.contains(url)
        return VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 42, height: 42)
            Text(url.lastPathComponent).font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.82)).lineLimit(1).frame(width: 72)
        }
        .frame(width: 76, height: 78)
        .background(selected ? NotchColors.bar.opacity(0.16) : Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? NotchColors.bar.opacity(0.75) : Color.white.opacity(0.07), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if selected {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(NotchColors.bar)
                    .background(Color.black, in: Circle()).offset(x: -2, y: -2)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { shelf.remove(url) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(NotchColors.dim)
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
