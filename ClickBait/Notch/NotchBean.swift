import AppKit
import ClickBaitCore
import IOKit.ps
import SwiftUI

/// The notch's bean (`Bean`): a pearl squircle, flatter at the bottom, with kaomoji eyes, a
/// drawn mouth, a little blush, and a glow and badge in ClickBait's state colours. It breathes,
/// blinks, looks toward the pointer, hops when the mood changes, wobbles on an error and dozes
/// off after `Bean.sleepAfter` idle. Reduce Motion keeps it still (the eyes still change).
/// While nothing else is going on it feels the Mac (`Bean.mood(for:)`, `MacVitals`, read only
/// while it's on screen): panicked at full load, flushed when hot, tired or asleep on a low
/// battery; pointing at it says why.
struct NotchBean: View {
    let mood: Bean.Mood
    var size: CGFloat = 26
    var badge = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vitals = MacVitals()
    @State private var eyes = Bean.eyes(for: .idle, avoiding: nil)
    @State private var idleSince = Date()
    @State private var hops = 0
    @State private var wobbles = 0

    var body: some View {
        let felt = mood == .idle ? vitals.felt : nil
        let base = felt?.mood ?? mood
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let now = timeline.date
            let shown: Bean.Mood = base == .idle && now.timeIntervalSince(idleSince) > Bean.sleepAfter ? .sleepy : base
            BeanFace(mood: shown, eyes: shown == base ? eyes : Bean.eyePairs(for: .sleepy)[0], size: size,
                     time: reduceMotion ? 0 : now.timeIntervalSinceReferenceDate,
                     look: reduceMotion ? .zero : Self.look(), badge: badge)
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
        .onAppear { vitals.start() }
        .onDisappear { vitals.stop() }
        .help(felt?.reason ?? "")
        .accessibilityElement()
        .accessibilityLabel("ClickBait, \(base.rawValue)\(felt.map { ", \($0.reason)" } ?? "")")
    }

    /// Where the pointer is from the notch (top middle of the main screen), -1…1 each way.
    private static func look() -> CGPoint {
        guard let screen = NSScreen.main else { return .zero }
        let mouse = NSEvent.mouseLocation
        let dx = (mouse.x - screen.frame.midX) / (screen.frame.width / 2)
        let dy = (screen.frame.maxY - mouse.y) / screen.frame.height
        return CGPoint(x: max(-1, min(1, dx)), y: max(0, min(1, dy * 2)))
    }

    /// The glow, tint and badge colour for each mood.
    static func color(for mood: Bean.Mood) -> Color {
        switch mood {
        case .idle, .sleepy, .panicked, .warm, .tired: CompanionTone.idle.color
        case .listening, .thinking: CompanionTone.processing.color
        case .working, .happy: CompanionTone.action.color
        case .error: wine
        }
    }

    /// Nothing going on (idle, asleep, or only feeling the Mac): plain pearl, no state colour.
    static func isResting(_ mood: Bean.Mood) -> Bool {
        switch mood {
        case .idle, .sleepy, .panicked, .warm, .tired: true
        case .listening, .thinking, .working, .happy, .error: false
        }
    }

    /// Errors are Wine (user's pick over Burgundy and Tyrian, 2026-10-21).
    static let wine = Color(hex: 0x9B1B48)
}

/// One frame of the bean, drawn from its mood, eyes, the clock (breathing and blinks) and
/// where it's looking.
struct BeanFace: View {
    let mood: Bean.Mood
    let eyes: String
    let size: CGFloat
    var time: TimeInterval = 0
    var look: CGPoint = .zero
    var badge = true
    /// A pill's small bean: filled with its colour (no pearl, no glow).
    var solid = false

    private static let pearlTop = Color(hex: 0xF3F3F6)
    private static let pearlBottom = Color(hex: 0xC9CAD1)
    private static let ink = Color(hex: 0x26272C)

    var body: some View {
        let tone = NotchBean.color(for: mood)
        let breath = mood == .sleepy ? sin(time * 1.6) : sin(time * 2.4)
        let squish = 0.025 * breath
        let blink = time > 0 && time.truncatingRemainder(dividingBy: 4.3) < 0.12
        let tremble = mood == .panicked && time > 0 ? CGFloat(sin(time * 60)) * size * 0.025 : 0
        let width = size, height = size * 0.86
        ZStack {
            if solid {
                BeanShape().fill(LinearGradient(colors: [tone.opacity(0.95), tone], startPoint: .top, endPoint: .bottom))
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
        let pair = eyes.split(separator: " ").map(String.init)
        return VStack(spacing: height * 0.02) {
            HStack(spacing: width * 0.2) {
                ForEach(Array(pair.enumerated()), id: \.offset) { _, eye in
                    Text(eye)
                        .font(.system(size: size * 0.3, weight: .heavy, design: .rounded))
                        .fixedSize()
                        .frame(width: width * 0.16)
                }
            }
            .scaleEffect(y: blink ? 0.1 : mood == .tired ? 0.6 : 1)
            ZStack {
                let flush = mood == .warm
                HStack(spacing: width * (flush ? 0.36 : 0.42)) {
                    ForEach(0..<2, id: \.self) { _ in
                        Ellipse().fill(Color(hex: 0xFF8FA3).opacity(solid ? 0 : flush ? 0.8 : 0.35))
                            .frame(width: width * (flush ? 0.2 : 0.14), height: height * (flush ? 0.11 : 0.08))
                    }
                }
                BeanMouth(mouth: Bean.mouth(for: mood))
                    .stroke(Self.ink, style: StrokeStyle(lineWidth: max(1, size * 0.05), lineCap: .round, lineJoin: .round))
                    .frame(width: width * 0.16, height: height * 0.1)
            }
        }
        .foregroundStyle(Self.ink)
        .offset(y: height * 0.04)
    }

    @ViewBuilder private func badgeView(tone: Color) -> some View {
        let mark: String? = switch mood {
        case .thinking: "···"
        case .error: "!"
        case .happy: "✓"
        case .sleepy: "z"
        case .idle, .listening, .working, .panicked, .warm, .tired: nil
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

/// A wide squircle (superellipse): rounder on top, flatter at the bottom.
struct BeanShape: Shape {
    func path(in rect: CGRect) -> Path {
        let a = rect.width / 2, b = rect.height / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for step in 0...96 {
            let t = Double(step) / 96 * 2 * .pi
            let c = cos(t), s = sin(t)
            let n = s > 0 ? 3.4 : 2.3  // y grows downward: the bottom is the flatter half
            let x = a * copysign(pow(abs(c), 2 / n), c)
            let y = b * copysign(pow(abs(s), 2 / n), s)
            let point = CGPoint(x: center.x + x, y: center.y + y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// The bean's own mouth, drawn in its frame.
struct BeanMouth: Shape {
    let mouth: Bean.Mouth

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch mouth {
        case .smile:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.2), control: CGPoint(x: rect.midX, y: rect.maxY))
        case .grin:
            path.move(to: CGPoint(x: rect.minX - rect.width * 0.15, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX + rect.width * 0.15, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.6))
            path.closeSubpath()
        case .open:
            path.addEllipse(in: CGRect(x: rect.midX - rect.height * 0.4, y: rect.minY, width: rect.height * 0.8, height: rect.height))
        case .flat:
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.15, y: rect.midY))
        case .frown:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY))
        }
        return path
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
