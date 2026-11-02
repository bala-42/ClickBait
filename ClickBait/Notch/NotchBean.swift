import AppKit
import ClickBaitCore
import IOKit.ps
import SwiftUI

/// The notch's bean (`Bean`): a soft pearl squircle, wider than tall, with pill eyes and no
/// mouth (blushing only when the Mac runs hot), and a glow and badge in ClickBait's state colours. It breathes,
/// blinks, looks toward the pointer, hops when the mood changes, wobbles on an error and dozes
/// off after `Bean.sleepAfter` idle (opening the notch wakes it). Reduce Motion keeps it still (the eyes still change).
/// While nothing else is going on it feels the Mac (`Bean.mood(for:)`, `MacVitals`, read only
/// while it's on screen): panicked at full load, flushed when hot, tired or asleep on a low
/// battery; pointing at it says why.
struct NotchBean: View {
    let mood: Bean.Mood
    var size: CGFloat = 26
    var badge = true
    /// The notch is open: being looked at wakes it (it only dozes off unwatched).
    var awake = false
    /// Its face while played with in space (`SpaceToyPlay`), over the resting one.
    var toyFace: (mood: Bean.Mood, eyes: Bean.EyePair)?
    /// On screen: hidden (the notch folded), its clock stops, as nothing of it is drawn.
    var shown = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vitals = MacVitals()
    @State private var eyes = Bean.eyes(for: .idle, avoiding: nil)
    @State private var idleSince = Date()
    @State private var hops = 0
    @State private var wobbles = 0
    @State private var gaze = BeanGaze()
    /// A pet (user's choice, 2026-10-23): pointed at, it beams and blushes; clicked, it hops
    /// and squishes.
    @State private var petted = false
    @State private var squishes = 0

    var body: some View {
        let felt = mood == .idle ? vitals.felt : nil
        let base = felt?.mood ?? mood
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !shown)) { timeline in
            let now = timeline.date
            let dozing = base == .idle && now.timeIntervalSince(idleSince) > Bean.sleepAfter
            // Petted while resting: chevron eyes and a blush (`warm`), never a state's colour.
            let beaming = petted && NotchBean.isResting(base)
            let toy = NotchBean.isResting(base) ? toyFace : nil
            let shown: Bean.Mood = toy?.mood ?? (beaming ? .warm : dozing ? .sleepy : base)
            let face = toy?.eyes ?? (beaming ? .both(.chevron) : dozing ? Bean.eyePairs(for: .sleepy)[0] : eyes)
            BeanFace(mood: shown, eyes: face, size: size,
                     time: reduceMotion ? 0 : now.timeIntervalSinceReferenceDate,
                     look: reduceMotion ? .zero : gaze.look(at: NSEvent.mouseLocation), badge: badge)
        }
        .background(GazeAnchor(gaze: gaze))
        .keyframeAnimator(initialValue: CGSize(width: 1, height: 1), trigger: squishes) { content, scale in
            content.scaleEffect(x: scale.width, y: scale.height, anchor: .bottom)
        } keyframes: { _ in
            SpringKeyframe(CGSize(width: 1.18, height: 0.8), duration: 0.1)
            SpringKeyframe(CGSize(width: 0.92, height: 1.1), duration: 0.14)
            SpringKeyframe(CGSize(width: 1, height: 1), duration: 0.3, spring: .bouncy)
        }
        .keyframeAnimator(initialValue: 0.0, trigger: hops) { content, lift in
            content.offset(y: -lift)
        } keyframes: { _ in
            SpringKeyframe(size * 0.18, duration: 0.14)
            SpringKeyframe(0, duration: 0.3, spring: .bouncy)
        }
        .keyframeAnimator(initialValue: 0.0, trigger: wobbles) { content, angle in
            content.rotationEffect(.degrees(angle), anchor: .bottom)
        } keyframes: { _ in
            CubicKeyframe(-8, duration: 0.07)
            CubicKeyframe(7, duration: 0.1)
            CubicKeyframe(-4, duration: 0.1)
            CubicKeyframe(0, duration: 0.12)
        }
        .onChange(of: base, initial: true) { _, new in
            eyes = Bean.eyes(for: new, avoiding: eyes)
            if new != .idle { idleSince = Date() }
            guard !reduceMotion else { return }
            if new == .error || new == .panicked { wobbles += 1 } else if new != .idle, new != .tired, new != .sleepy { hops += 1 }
        }
        .onChange(of: mood) { _, _ in idleSince = Date() }
        .onChange(of: awake) { _, now in if now { idleSince = Date() } else { petted = false } }
        .onHover { inside in
            guard awake else { return }
            petted = inside
            idleSince = Date()  // a pet wakes it
        }
        .onTapGesture {
            guard awake else { return }
            idleSince = Date()
            petted = true
            guard !reduceMotion else { return }
            squishes += 1
            hops += 1
        }
        .onAppear { vitals.start() }
        .onDisappear { vitals.stop() }
        // At rest it pulls a new face every 4–8 s, so it feels alive (user's ask, 2026-10-24).
        .task(id: base) {
            guard base == .idle else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 4...8)))
                guard !Task.isCancelled, !petted else { continue }
                eyes = Bean.dockFace(avoiding: [eyes])
            }
        }
        .help(felt?.reason ?? "")
        .accessibilityElement()
        .accessibilityLabel("ClickBait, \(base.rawValue)\(felt.map { ", \($0.reason)" } ?? "")")
    }

    /// The glow, tint and badge colour for each mood.
    static func color(for mood: Bean.Mood) -> Color {
        switch mood {
        case .idle, .sleepy, .panicked, .warm, .tired, .hello: CompanionTone.idle.color
        case .listening, .thinking: CompanionTone.processing.color
        case .working, .happy: CompanionTone.action.color
        case .error: CompanionTone.problem
        }
    }

    /// Nothing going on (idle, asleep, or only feeling the Mac): plain pearl, no state colour.
    static func isResting(_ mood: Bean.Mood) -> Bool {
        switch mood {
        case .idle, .sleepy, .panicked, .warm, .tired, .hello: true
        case .listening, .thinking, .working, .happy, .error: false
        }
    }
}

/// One frame of the bean, drawn from its mood, eyes, the clock (breathing and blinks) and
/// where it's looking.
struct BeanFace: View {
    let mood: Bean.Mood
    let eyes: Bean.EyePair
    let size: CGFloat
    var time: TimeInterval = 0
    var look: CGPoint = .zero
    var badge = true
    /// A pill's small bean: filled with its colour (no pearl, no glow).
    var solid = false
    /// The Mirror pill's bean: chrome with a rainbow sheen, turning with `sheen` (seconds).
    var holo = false
    var sheen: TimeInterval = 0
    /// A colour of its own instead of the mood's (the Music pill, a dock job's tone).
    var tint: Color?
    /// Its eyes' colour instead of the default (ink on a pale tint).
    var eyeColor: Color?

    static let pearlTop = Color(hex: 0xF3F3F6)
    static let pearlBottom = Color(hex: 0xC9CAD1)
    private static let ink = Color(hex: 0x26272C)
    /// The asleep bean's X-ray glow: a ghostly blue-green (user's ask, 2026-10-24).
    private static let xray = Color(hex: 0x3DF5C8)
    private static let holoHues = [0xFFB8E8, 0xB8E4FF, 0xCDB8FF, 0xB8FFDD, 0xFFF1B8, 0xFFB8E8].map { Color(hex: $0) }

    var body: some View {
        let tone = tint ?? NotchBean.color(for: mood)
        let breath = mood == .sleepy ? sin(time * 1.6) : sin(time * 2.4)
        let squish = 0.025 * breath
        let blink = time > 0 && time.truncatingRemainder(dividingBy: 4.3) < 0.12
        let tremble = mood == .panicked && time > 0 ? CGFloat(sin(time * 60)) * size * 0.025 : 0
        let width = size, height = size * BeanShape.aspect
        ZStack {
            if holo {
                // Silver underneath, the rainbow turning over it, and a white glint sweeping across.
                let sweep = sheen.truncatingRemainder(dividingBy: 3) / 3 * 1.6 - 0.3
                // On a Windows square (Mirror's blue) the rainbow is a lighter sheen over its colour.
                let shade = tint.flatMap(NotchPalette.windowsShade)
                BeanShape()
                    .fill(LinearGradient(colors: shade ?? [.white, Color(hex: 0xB9BDC7)],
                                         startPoint: shade == nil ? .top : .topLeading, endPoint: shade == nil ? .bottom : .bottomTrailing))
                    .overlay(BeanShape().fill(AngularGradient(colors: Self.holoHues, center: .center,
                                                              angle: .degrees(sheen * 50))).opacity(shade == nil ? 0.8 : 0.22))
                    .overlay(BeanShape().fill(LinearGradient(stops: [
                        .init(color: .white.opacity(0), location: sweep - 0.15),
                        .init(color: .white.opacity(0.85), location: sweep),
                        .init(color: .white.opacity(0), location: sweep + 0.15),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(BeanShape().stroke(.white.opacity(0.9), lineWidth: 0.75))
            } else if solid, let tint, let shade = NotchPalette.windowsShade(tint) {
                // A glossy Windows 7 square: shaded corner to corner, a gel highlight on top.
                BeanShape().fill(LinearGradient(colors: shade, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(alignment: .top) {
                        Ellipse()
                            .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                            .frame(width: width * 0.86, height: height * 0.5)
                            .offset(y: height * 0.04)
                    }
                    .overlay(BeanShape().stroke(.white.opacity(0.35), lineWidth: 0.5))
            } else if solid {
                BeanShape().fill(LinearGradient(colors: [tone.opacity(0.95), tone], startPoint: .top, endPoint: .bottom))
            } else if mood == .sleepy {
                // Asleep: see-through, like an X-ray (user's choice, 2026-10-24): a glowing
                // blue-green outline over a faint film, its z eyes showing inside, flickering
                // faintly and unevenly like something paranormal.
                let flicker = time > 0 ? 0.82 + 0.18 * sin(time * 3.1) * sin(time * 7.7) : 1
                BeanShape()
                    .fill(RadialGradient(colors: [Self.xray.opacity(0.3), Self.xray.opacity(0.05)],
                                         center: .center, startRadius: 0, endRadius: width * 0.6))
                    .overlay(BeanShape().stroke(Self.xray.opacity(0.95 * flicker), lineWidth: max(1, size * 0.025)))
                    .overlay(BeanShape().scale(0.84).stroke(Self.xray.opacity(0.28 * flicker), lineWidth: max(0.5, size * 0.012)))
                    .shadow(color: Self.xray.opacity(0.7 * flicker), radius: size * 0.16)
            } else {
                // Plain pearl with a soft white glow at rest; a state tints it and glows its colour.
                let resting = NotchBean.isResting(mood)
                BeanShape()
                    .fill(LinearGradient(colors: [Self.pearlTop, Self.pearlBottom], startPoint: .top, endPoint: .bottom))
                    .overlay(BeanShape().fill(tone.opacity(resting ? 0 : 0.14)))
                    .overlay(BeanShape().stroke(.white.opacity(0.6), lineWidth: 0.5))
                    .shadow(color: resting ? .white.opacity(mood == .sleepy ? 0.12 : 0.25) : tone.opacity(0.65), radius: size * 0.22)
            }
            face(width: width, height: height, blink: blink)
                .offset(x: look.x * size * 0.06 + tremble, y: look.y * size * 0.04)
            if mood == .panicked {
                Image(systemName: "drop.fill")
                    .font(.system(size: size * 0.2))
                    .foregroundStyle(Color(hex: 0x8FD3FF))
                    .offset(x: -width * 0.36, y: -height * 0.18)
            }
        }
        .frame(width: width, height: height)
        .scaleEffect(x: 1 + squish, y: 1 - squish, anchor: .bottom)
        .overlay(alignment: .topTrailing) { if badge { badgeView(tone: tone) } }
        .frame(width: width + size * 0.2, height: height + size * 0.2)
    }

    private func face(width: CGFloat, height: CGFloat, blink: Bool) -> some View {
        ZStack {
            if mood == .warm, !solid {
                HStack(spacing: width * 0.36) {
                    ForEach(0..<2, id: \.self) { _ in
                        Ellipse().fill(Color(hex: 0xFF8FA3).opacity(0.8))
                            .frame(width: width * 0.2, height: height * 0.11)
                    }
                }
                .offset(y: height * 0.2)
            }
            HStack(spacing: width * 0.04) {
                BeanEye(eye: eyes.left, size: size)
                BeanEye(eye: eyes.right, size: size)
            }
            .scaleEffect(y: blink ? 0.12 : 1)
            // Height and tilt glide to the new pair; Reduce Motion (time 0) swaps at once.
            .animation(time > 0 ? .spring(duration: 0.3, bounce: 0.35) : nil, value: eyes)
        }
        // Pearl and chrome eyes are ink; a pill's solid bean wears white eyes on its colour; an
        // X-ray (asleep) bean's glow blue-green.
        .foregroundStyle(eyeColor ?? (solid && !holo ? .white : mood == .sleepy && !holo ? Self.xray : Self.ink))
    }

    @ViewBuilder private func badgeView(tone: Color) -> some View {
        let mark: String? = switch mood {
        case .thinking: "···"
        case .error: "!"
        case .happy: "✓"
        case .idle, .listening, .working, .panicked, .warm, .tired, .hello, .sleepy: nil
        }
        if let mark {
            Text(mark)
                .font(.system(size: size * 0.24, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, size * 0.06)
                .frame(minWidth: size * 0.36, minHeight: size * 0.36)
                .background(tone, in: Capsule())
                .overlay(Capsule().stroke(NotchPalette.ink, lineWidth: 1.5))
        }
    }
}

/// A soft, wide squircle: a superellipse with exponent `exponent` (2 is an ellipse, 4–5 an
/// app icon), `aspect` times as tall as it is wide.
struct BeanShape: Shape {
    static let exponent = 2.7
    static let aspect = 0.77

    func path(in rect: CGRect) -> Path {
        let a = rect.width / 2, b = rect.height / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for step in 0...96 {
            let t = Double(step) / 96 * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = a * copysign(pow(abs(c), 2 / Self.exponent), c)
            let y = b * copysign(pow(abs(s), 2 / Self.exponent), s)
            let point = CGPoint(x: center.x + x, y: center.y + y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// One drawn eye, centred in a fixed slot so a pair never shifts when its shapes change.
struct BeanEye: View {
    let eye: Bean.Eye
    let size: CGFloat

    var body: some View {
        Group {
            switch eye {
            case .pill(let height, let tilt):
                Capsule().frame(width: size * 0.125, height: size * 0.3 * height).rotationEffect(.degrees(tilt))
            case .dash(let tilt):
                Capsule().frame(width: size * 0.17, height: size * 0.075).rotationEffect(.degrees(tilt))
            case .dot:
                Circle().frame(width: size * 0.15, height: size * 0.15)
            case .chevron:
                Chevron()
                    .stroke(style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.15, height: size * 0.09)
            case .z:
                ZMark()
                    .stroke(style: StrokeStyle(lineWidth: size * 0.055, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.14, height: size * 0.14)
            }
        }
        .frame(width: size * 0.2, height: size * 0.38)
    }

    /// A "z": top bar, diagonal, bottom bar.
    private struct ZMark: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            return path
        }
    }

    /// An upturned "^".
    private struct Chevron: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            return path
        }
    }
}

/// Where the pointer is, from mouse moves (no polling), for the beans' eyes to follow.
@MainActor @Observable
final class PointerWatch {
    static let shared = PointerWatch()
    private(set) var location = NSEvent.mouseLocation
    @ObservationIgnored private var monitors: [Any] = []

    private init() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated { PointerWatch.shared.moved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { PointerWatch.shared.moved() }
            return event
        }) { monitors.append(local) }
    }

    @ObservationIgnored private var lastUpdate = Date.distantPast

    /// Only moves of 8 pt or more, at most 20 times a second, redraw the beans: each dock tile
    /// is a window of its own, and every redraw was more for the render server to take.
    private func moved() {
        let now = NSEvent.mouseLocation
        guard abs(now.x - location.x) + abs(now.y - location.y) >= 8, Date().timeIntervalSince(lastUpdate) >= 0.05 else { return }
        lastUpdate = Date()
        location = now
    }
}

/// A bean's place on screen, so its eyes look at the pointer from where it is.
@MainActor
final class BeanGaze {
    weak var view: NSView?

    /// -1…1 each way (y down), full at 160 pt away.
    func look(at mouse: NSPoint) -> CGPoint {
        guard let view, let window = view.window else { return .zero }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let dx = (mouse.x - frame.midX) / 160, dy = (frame.midY - mouse.y) / 160
        return CGPoint(x: max(-1, min(1, dx)), y: max(-1, min(1, dy)))
    }
}

/// An empty view marking the bean's place for `BeanGaze`.
struct GazeAnchor: NSViewRepresentable {
    let gaze: BeanGaze

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        gaze.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { gaze.view = view }
}

/// A bean whose eyes follow the pointer (`PointerWatch`); still with Reduce Motion.
struct Gazing<Content: View>: View {
    @ViewBuilder let content: (CGPoint) -> Content
    @State private var gaze = BeanGaze()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content(reduceMotion ? .zero : gaze.look(at: PointerWatch.shared.location))
            .background(GazeAnchor(gaze: gaze))
    }
}

extension OverlayModel {
    /// What the bean feels, from what the companion is doing.
    var beanMood: Bean.Mood {
        if isDictating { return bubble == .listening ? .listening : .thinking }
        if isSnipThinking || isTutorialChecking { return .thinking }
        return switch bubble {
        case .listening: .listening
        case .thinking, .explaining: .thinking
        case .working: .working
        case .done, .greeting, .jobResult: .happy
        case .error: .error
        case .idle, .answer, .hint: .idle
        }
    }
}

/// The Mac's load, heat and battery for the bean, every 3 s while it's on screen. Read only:
/// processor ticks (`host_statistics`), `ProcessInfo.thermalState`, and the power source.
@MainActor @Observable
final class MacVitals {
    private(set) var felt: (mood: Bean.Mood, reason: String)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastTicks: (busy: UInt64, total: UInt64)?

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        lastTicks = nil
        felt = nil
    }

    private func sample() {
        let ticks = Self.cpuTicks()
        var cpu = 0.0
        if let ticks, let last = lastTicks, ticks.total > last.total {
            cpu = Double(ticks.busy &- last.busy) / Double(ticks.total - last.total)
        }
        lastTicks = ticks
        let thermal = ProcessInfo.processInfo.thermalState
        let power = Self.battery()
        let next = Bean.mood(for: .init(cpu: cpu, hot: thermal == .serious || thermal == .critical,
                                        battery: power?.level, charging: power?.charging ?? false))
        if next?.mood != felt?.mood || next?.reason != felt?.reason { felt = next }
    }

    /// Busy and total processor ticks since boot, all cores.
    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// The internal battery's level and whether it's on power; nil without one.
    private static func battery() -> (level: Double, charging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (Double(current) / Double(max), info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}

/// The shelf's AirDrop pad as a bean (user's ask, 2026-11-02): three eyes, faded lime, a
/// sibling of the notch's bean. Pale, so it never reads as Shamrock (an action). Eyes: pills at
/// rest, wide dots bouncing while something's dropped on it or a recipient is being chosen,
/// dashes when sending failed.
struct AirDropBean: View {
    enum Look { case ready, eager, problem }
    let look: Look
    var size: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hop = false

    static let lime = Color(hex: 0xDCEDB4)
    static let limeShade = Color(hex: 0xB8D38C)
    private static let ink = Color(hex: 0x26272C)

    var body: some View {
        let eye: Bean.Eye = switch look {
        case .ready: .pill(height: 0.8)
        case .eager: .dot
        case .problem: .dash()
        }
        ZStack {
            BeanShape().fill(LinearGradient(colors: [Self.lime, Self.limeShade], startPoint: .top, endPoint: .bottom))
            BeanShape().stroke(Color.white.opacity(0.35), lineWidth: 0.6)
            HStack(spacing: size * 0.1) {
                ForEach(0..<3, id: \.self) { _ in BeanEye(eye: eye, size: size * 0.8) }
            }
            .foregroundStyle(Self.ink)
            .offset(y: -size * 0.04)
        }
        .frame(width: size, height: size * BeanShape.aspect)
        .offset(y: hop ? -size * 0.12 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.5), value: hop)
        .task(id: look) {
            hop = false
            guard look == .eager, !reduceMotion else { return }
            while !Task.isCancelled {
                hop.toggle()
                try? await Task.sleep(for: .milliseconds(420))
            }
        }
        .accessibilityHidden(true)
    }
}
