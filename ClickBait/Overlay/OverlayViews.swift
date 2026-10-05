import ClickBaitCore
import SwiftUI

/// An equilateral triangle with a vertex pointing up; rotate it to aim.
struct EquilateralTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        // Side = width; height = side × √3/2, centred vertically in the rect.
        let side = rect.width
        let height = side * 3.squareRoot() / 2
        let top = rect.midY - height / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top + height))
        path.addLine(to: CGPoint(x: rect.minX, y: top + height))
        path.closeSubpath()
        return path
    }
}

/// The companion: an equilateral triangle in the current state's colour, its vertex
/// aimed up-left at the cursor — or at a target while guiding. Pulses while something
/// is in progress.
struct CompanionTriangle: View {
    let tone: CompanionTone
    let pulsing: Bool
    /// Thinking: a third of a turn at a time, springing past and settling back, then a
    /// short rest. A triangle looks the same every 120°, so each tick ends where it began.
    var spinning: Bool = false
    /// Degrees clockwise from vertex-up.
    var angle: Double = Self.restingAngle
    static let size: CGFloat = 15
    /// Up-left, at the cursor.
    static let restingAngle: Double = -45

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One full beat (swell and back), as the old 0.7 s autoreversing pulse.
    private static let beatPeriod: Double = 1.4
    /// When the current pulse began, so every pulse starts from rest instead of mid-swell.
    @State private var pulseStart = Date()
    @State private var spinStart = Date()
    /// Where a stopped spin was, springing to the nearest resting third.
    @State private var settle: Double = 0
    private static let tickTime: Double = 0.5
    private static let restTime: Double = 0.4

    var body: some View {
        // Reduce Motion: no turning; thinking pulses gently instead.
        let beating = pulsing || (spinning && reduceMotion)
        let turning = spinning && !reduceMotion
        // Both are computed from the clock, not repeatForever animations: those kept
        // running after they stopped (each settle/unsettle while pointing started another),
        // so the triangle went on rippling blue when it should have been idle. Paused, the
        // timeline draws nothing extra.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !beating && !turning)) { context in
            let beat = beating ? Self.beat(after: context.date.timeIntervalSince(pulseStart)) : 0
            let spin = turning ? Self.spinAngle(after: context.date.timeIntervalSince(spinStart)) : settle
            EquilateralTriangle()
                .fill(tone.color.opacity(0.9))
                .frame(width: Self.size, height: Self.size)
                .rotationEffect(.degrees(angle + spin))  // angle smoothed by OverlayController
                .shadow(color: tone.color.opacity(0.45 + 0.45 * beat), radius: 3 + 4 * beat)
                .scaleEffect(reduceMotion ? 1 : 1 + 0.18 * beat)
                .opacity(reduceMotion ? 1 - 0.4 * beat : 1)
        }
        .frame(width: Self.size * 1.7, height: Self.size * 1.7)
        .animation(.easeInOut(duration: 0.25), value: tone)
        .animation(.easeOut(duration: 0.2), value: beating)  // settle back softly when it stops
        .onChange(of: beating) { _, isBeating in
            if isBeating { pulseStart = .now }
        }
        .onChange(of: turning) { _, isTurning in
            if isTurning {
                spinStart = .now
                return
            }
            // Stopped mid-tick: spring to the nearest third (they all look the same), so the
            // triangle never snaps when the answer arrives.
            let now = Self.spinAngle(after: Date().timeIntervalSince(spinStart)).truncatingRemainder(dividingBy: 120)
            settle = now
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { settle = now > 60 ? 120 : 0 }
        }
        .accessibilityHidden(true)
    }

    /// Thirds of a turn: each tick springs ~16° past and settles back (an underdamped
    /// step), then rests. Ends of ticks and rests are exact multiples of 120°.
    private static func spinAngle(after elapsed: TimeInterval) -> Double {
        let cycle = tickTime + restTime
        let t = max(elapsed, 0)
        let ticks = (t / cycle).rounded(.down)
        let u = (t - ticks * cycle) / tickTime
        let progress = u >= 1 ? 1 : 1 - exp(-6 * u) * cos(3 * .pi * u)
        return 120 * (ticks + progress)
    }

    /// 0 → 1 → 0 over one period, eased like the old easeInOut swell.
    private static func beat(after elapsed: TimeInterval) -> Double {
        let phase = max(elapsed, 0).truncatingRemainder(dividingBy: beatPeriod) / beatPeriod
        return (1 - cos(phase * 2 * .pi)) / 2
    }
}

/// A few words beside the triangle, in the guide label's style: "Compressed 3 files",
/// "Screen Recording is off…". Wraps to a few lines for longer messages.
private struct TinyPill: View {
    let text: String
    /// Words only when nil (what was heard, the tutorial's "checking…").
    var symbol: String?
    let tone: CompanionTone
    /// Problems are black and white, so they never read as one of the four states.
    var isProblem = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .wrapped(text, maxWidth: 270)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .modifier(ToneFill(fill: isProblem ? Color(white: 0.13).opacity(0.94) : tone.color.opacity(0.9),
                           glow: isProblem ? .black.opacity(0.6) : tone.color.opacity(0.45),
                           shape: RoundedRectangle(cornerRadius: 11, style: .continuous)))
        .padding(.top, 3)
    }
}

extension View {
    /// Text that's as wide as it needs up to `maxWidth`, then wraps onto as many lines
    /// as it takes. Measured explicitly: inside the overlay's fixed-size layout SwiftUI
    /// would otherwise lay a long label out on one line, or cut it off.
    func wrapped(_ text: String, maxWidth: CGFloat, size: CGFloat = 12, weight: NSFont.Weight = .semibold) -> some View {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let widest = text.split(whereSeparator: \.isNewline)
            .map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return self
            .frame(width: min(ceil(widest) + 2, maxWidth), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Pills wear the triangle's colour (or black, for problems), so label and pointer
/// read as one. No outline: just the fill and a soft glow.
struct ToneFill<S: Shape>: ViewModifier {
    let fill: Color
    let glow: Color
    let shape: S

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .background(shape.fill(fill))
            .shadow(color: glow, radius: 3)
            .animation(.easeInOut(duration: 0.25), value: fill)
    }
}

/// What the guiding triangle is pointing at ("Share", "1/2 · File"). Lives in its own
/// panel so the controller can keep it on the far side of the triangle from the target.
struct GuideLabelView: View {
    let model: OverlayModel

    var body: some View {
        Group {
            if let label = model.guideLabel, !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .wrapped(label, maxWidth: 240)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .modifier(ToneFill(fill: model.tone.color.opacity(0.9), glow: model.tone.color.opacity(0.45),
                                       shape: RoundedRectangle(cornerRadius: 11, style: .continuous)))
                    .accessibilityLabel("ClickBait is pointing at \(model.guideTarget ?? label)")
                    .contentTransition(.opacity)  // names crossfade between stops
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.guideLabel)
        .padding(6)  // room for the glass shadow
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.guideLabelSize = $0 }
        .frame(width: OverlayModel.guideLabelCanvas.width, height: OverlayModel.guideLabelCanvas.height, alignment: .topLeading)
    }
}

/// While listening the triangle becomes a few bars that move with the user's voice.
struct ListeningWaveform: View {
    let level: Double
    let tone: CompanionTone

    /// Middle bars reach highest, like a voice-memo meter.
    private static let shape: [Double] = [0.55, 0.85, 1, 0.85, 0.55]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(Self.shape.indices, id: \.self) { index in
                    // A little independent wobble per bar so a steady voice still looks alive.
                    let wobble = reduceMotion ? 1 : 0.8 + 0.2 * sin(time * 11 + Double(index) * 1.7)
                    let height = 4 + 18 * level * Self.shape[index] * wobble
                    Capsule()
                        .fill(tone.color.opacity(0.95))
                        .frame(width: 3.5, height: height)
                }
            }
            .shadow(color: tone.color.opacity(0.5), radius: 3)
        }
        .frame(width: CompanionTriangle.size * 1.7, height: CompanionTriangle.size * 1.7)
        .accessibilityLabel("Listening")
    }
}

/// The companion that follows the cursor: the triangle, with a tiny pill beside it
/// when there's a result or a problem to show.
struct CompanionBubbleView: View {
    let model: OverlayModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let maxTextWidth: CGFloat = 300

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            Group {
                if model.bubble == .listening {
                    ListeningWaveform(level: model.waveLevel, tone: model.tone)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    CompanionTriangle(tone: model.tone, pulsing: model.isPulsing, spinning: model.isSpinning, angle: model.triangleAngle)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(2)
            if model.bubble.hasWords && !model.isGuiding {
                card
                    .transition(.scale(scale: 0.85, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .padding(4)
        .padding([.trailing, .bottom], 10)  // room for the shadow inside the panel
        .fixedSize()
        // The panel is a fixed, invisible canvas; tell the controller how big the
        // companion really is so it can keep it on screen.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.bubbleSize = $0 }
        .frame(width: OverlayModel.bubbleCanvas.width, height: OverlayModel.bubbleCanvas.height, alignment: .topLeading)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.8), value: model.bubble)
        .accessibilityElement(children: .combine)
    }

    /// Only things that need words get any: a result or a problem, as a tiny pill.
    /// Listening, thinking and working are shown by the triangle's colour and pulse.
    @ViewBuilder private var card: some View {
        switch model.bubble {
        case .thinking(let heard?):
            TinyPill(text: "“\(heard)”", tone: model.tone)
        case .working(let message):
            // A lowercase verb, names as they are: "opening Safari…", "moving to Documents…".
            TinyPill(text: message.prefix(1).lowercased() + message.dropFirst(), symbol: "gearshape.fill", tone: model.tone)
        case .idle, .listening, .thinking, .explaining:
            EmptyView()
        case .answer(let text), .done(let text):
            TinyPill(text: text, symbol: "checkmark", tone: model.tone)
        case .error(let message):
            TinyPill(text: message, symbol: "exclamationmark", tone: model.tone, isProblem: true)
        case .hint(let text):
            TinyPill(text: text, tone: model.tone)
        }
    }
}

struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        }
    }
}
