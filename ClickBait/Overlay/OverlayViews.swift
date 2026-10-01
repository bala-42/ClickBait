import ClickBaitCore
import SwiftUI

/// Fills one screen's overlay panel and draws the pointers that fall on that screen.
struct ScreenOverlayView: View {
    let model: OverlayModel
    /// The panel's screen frame in global AppKit points.
    let screenFrame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            SpeedTrailView(model: model, screenFrame: screenFrame)
            ForEach(Array(visiblePointers.enumerated()), id: \.offset) { index, pointer in
                PointerView(
                    label: pointer.label,
                    number: model.pointers.count > 1 ? index + 1 : nil
                )
                .position(localPosition(of: pointer))
                .id("\(model.pointerGeneration)-\(index)")
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
    }

    private var visiblePointers: [ScreenPointer] {
        model.pointers.filter { screenFrame.contains(CGPoint(x: $0.appKit.x, y: $0.appKit.y)) }
    }

    /// SwiftUI's origin is the panel's top-left; AppKit's is the bottom-left.
    private func localPosition(of pointer: ScreenPointer) -> CGPoint {
        CGPoint(x: pointer.appKit.x - screenFrame.minX, y: screenFrame.maxY - pointer.appKit.y)
    }
}

/// Sandevistan-style speed trail: neon afterimages of the companion arrowhead along its
/// recent fast path, coloured green → magenta by age, with a split-colour glitch.
struct SpeedTrailView: View {
    let model: OverlayModel
    let screenFrame: CGRect

    /// Edgerunners gradient, newest ghost to oldest: acid green, cyan, blue, violet, magenta.
    static let gradient: [(red: Double, green: Double, blue: Double)] = [
        (0.22, 1.0, 0.29), (0.0, 0.94, 1.0), (0.16, 0.45, 1.0), (0.58, 0.25, 1.0), (1.0, 0.17, 0.84),
    ]

    /// Colour at `position` along the gradient (0 = newest, 1 = oldest).
    static func color(at position: Double) -> Color {
        let scaled = min(max(position, 0), 1) * Double(gradient.count - 1)
        let lower = Int(scaled.rounded(.down)), upper = min(lower + 1, gradient.count - 1)
        let t = scaled - Double(lower)
        let a = gradient[lower], b = gradient[upper]
        return Color(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t, blue: a.blue + (b.blue - a.blue) * t)
    }

    var body: some View {
        TimelineView(.animation(paused: model.trail.isEmpty)) { timeline in
            Canvas { context, _ in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for point in model.trail {
                    let age = now - point.time
                    guard age >= 0, age < OverlayModel.trailLifetime else { continue }
                    let fade = 1 - age / OverlayModel.trailLifetime
                    let local = CGPoint(x: point.position.x - screenFrame.minX, y: screenFrame.maxY - point.position.y)
                    guard local.x > -40, local.y > -40, local.x < screenFrame.width + 40, local.y < screenFrame.height + 40
                    else { continue }
                    Self.drawGhost(in: &context, at: local, color: Self.color(at: age / OverlayModel.trailLifetime), opacity: fade)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One afterimage: cyan and magenta copies split sideways (the glitch), then the
    /// coloured ghost on top. Normal blending: additive glow vanishes on white pages.
    static func drawGhost(in context: inout GraphicsContext, at center: CGPoint, color: Color, opacity: Double) {
        let size = CompanionArrow.size
        let rect = CGRect(x: -size / 2, y: -size * 0.6, width: size, height: size * 1.2)
        let arrow = StealthArrow().path(in: rect)
        context.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .degrees(-45))
            layer.opacity = opacity
            let split = 2.0 * opacity
            layer.fill(arrow.offsetBy(dx: -split, dy: 0), with: .color(Self.color(at: 0.25).opacity(0.45)))
            layer.fill(arrow.offsetBy(dx: split, dy: 0), with: .color(Self.color(at: 1).opacity(0.45)))
            layer.fill(arrow, with: .color(color.opacity(0.85)))
            layer.stroke(arrow, with: .color(.white.opacity(0.6 * opacity)), lineWidth: 1)
        }
    }
}

/// A stealth arrowhead whose tip sits exactly on the target, with a small glass label
/// above its tail. Same look as the companion: translucent dark with a white edge.
struct PointerView: View {
    let label: String
    let number: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private static let arrowSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            labelPill
                .padding(.trailing, Self.arrowSize * 0.55)  // sit over the arrow's tail, not its tip
            AimedStealthArrow()
                .fill(.black.opacity(0.5))
                .overlay(AimedStealthArrow().stroke(.white, style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
                .frame(width: Self.arrowSize, height: Self.arrowSize)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        }
        .fixedSize()
        // The stack's bottom-right corner is the arrow's tip: pin it to the target.
        .frame(width: 1, height: 1, alignment: .bottomTrailing)
        .offset(x: appeared || reduceMotion ? 0 : -22, y: appeared || reduceMotion ? 0 : -22)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.75)) {
                appeared = true
            }
        }
        .accessibilityElement()
        .accessibilityLabel("ClickBait is pointing at \(label)")
    }

    @ViewBuilder private var labelPill: some View {
        if !label.isEmpty || number != nil {
            HStack(spacing: 5) {
                if let number {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .frame(width: 15, height: 15)
                        .background(.primary.opacity(0.12), in: Circle())
                }
                if !label.isEmpty {
                    Text(label).font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .modifier(GlassBackground(shape: Capsule()))
        }
    }
}

/// A stealth arrowhead aimed down-right, with its tip at the bottom-right corner of the
/// rect so it can be pinned to a point.
struct AimedStealthArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let tip = CGPoint(x: rect.minX + size, y: rect.minY + size)
        // Unit vectors: back along the diagonal toward the tail, and across it.
        let back = CGVector(dx: -1 / 2.squareRoot(), dy: -1 / 2.squareRoot())
        let across = CGVector(dx: 1 / 2.squareRoot(), dy: -1 / 2.squareRoot())
        let length = size * 0.97, halfWidth = length * 0.4
        func point(along: CGFloat, side: CGFloat) -> CGPoint {
            CGPoint(x: tip.x + back.dx * along + across.dx * side, y: tip.y + back.dy * along + across.dy * side)
        }
        var path = Path()
        path.move(to: tip)
        path.addLine(to: point(along: length, side: halfWidth))
        path.addQuadCurve(to: point(along: length * 0.68, side: 0), control: point(along: length * 0.8, side: halfWidth * 0.3))
        path.addQuadCurve(to: point(along: length, side: -halfWidth), control: point(along: length * 0.8, side: -halfWidth * 0.3))
        path.closeSubpath()
        return path
    }
}

/// A stealth (barbed) arrowhead pointing up: straight flanks, swept-back barbs and a
/// concave notch at the back. Rotate it to aim.
struct StealthArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let tip = CGPoint(x: rect.midX, y: rect.minY)
        let rightBarb = CGPoint(x: rect.maxX, y: rect.maxY)
        let leftBarb = CGPoint(x: rect.minX, y: rect.maxY)
        let notch = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.68)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: rightBarb)
        path.addQuadCurve(to: notch, control: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.minY + rect.height * 0.8))
        path.addQuadCurve(to: leftBarb, control: CGPoint(x: rect.midX - rect.width * 0.12, y: rect.minY + rect.height * 0.8))
        path.closeSubpath()
        return path
    }
}

/// The companion's arrowhead: aims up-left at the real cursor. Translucent black (35%) with
/// a white edge so it reads on light and dark content (windows can't invert the
/// pixels of other apps behind them).
struct CompanionArrow: View {
    static let size: CGFloat = 14

    var body: some View {
        StealthArrow()
            .fill(.black.opacity(0.35))
            .overlay(StealthArrow().stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)))
            .frame(width: Self.size, height: Self.size * 1.2)
            .rotationEffect(.degrees(-45))
            .frame(width: Self.size * 1.6, height: Self.size * 1.6)
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }
}

/// The companion that follows the cursor. Idle it's a small arrowhead; when there's
/// something to say, the arrowhead itself grows into the bubble (and shrinks back).
struct CompanionBubbleView: View {
    let model: OverlayModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var morph
    @State private var breathing = false

    static let maxTextWidth: CGFloat = 300

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.bubble == .idle {
                CompanionArrow()
                    .matchedGeometryEffect(id: "companion", in: morph)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .topLeading)))
            } else {
                card
                    .matchedGeometryEffect(id: "companion", in: morph)
                    .transition(.opacity)
            }
        }
        .padding(4)
        .padding([.trailing, .bottom], 10)  // room for the shadow inside the panel
        .fixedSize()
        // The panel is a fixed, invisible canvas; tell the controller how big the
        // companion really is so it can keep it on screen.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.bubbleSize = $0 }
        .frame(width: OverlayModel.bubbleCanvas.width, height: OverlayModel.bubbleCanvas.height, alignment: .topLeading)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.78), value: model.bubble)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { breathing = true }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var card: some View {
        switch model.bubble {
        case .idle:
            EmptyView()
        case .explaining(let excerpt):
            BubbleCard(symbol: "text.magnifyingglass", tint: .teal, title: "Explaining", message: Self.quote(excerpt),
                       showsSpinner: true)
        case .listening:
            BubbleCard(symbol: "mic.fill", tint: .red, title: "Listening", message: "Let go of ⌃⌥ when you're done.",
                       pulsing: breathing && !reduceMotion)
        case .thinking(let heard):
            BubbleCard(symbol: "sparkles", tint: .purple, title: "Thinking", message: heard.map { "“\($0)”" },
                       showsSpinner: true)
        case .answer(let text):
            BubbleCard(symbol: "cursorarrow.rays", tint: .accentColor, title: "ClickBait", message: text)
        case .done(let message):
            BubbleCard(symbol: "checkmark", tint: .green, title: "Done", message: message)
        case .error(let message):
            BubbleCard(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Couldn't do that", message: message)
        }
    }

    private static func quote(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "“" + (oneLine.count > 90 ? oneLine.prefix(89) + "…" : Substring(oneLine)) + "”"
    }
}

/// A clean card in the macOS notification style: tinted icon, small title, message.
/// Liquid Glass on macOS 26+, the standard blurred material before that.
private struct BubbleCard: View {
    let symbol: String
    let tint: Color
    let title: String
    var message: String?
    var showsSpinner = false
    var pulsing = false

    private static let corner: CGFloat = 16

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.16), in: Circle())
                .scaleEffect(pulsing ? 1.08 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if showsSpinner {
                        ProgressView().controlSize(.mini)
                    }
                }
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: CompanionBubbleView.maxTextWidth, alignment: .leading)
            .padding(.top, 4)
        }
        .padding(.leading, 9)
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: Self.corner, style: .continuous)))
        // While the arrowhead grows into the card, keep the text inside the shape.
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
    }
}

private struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        }
    }
}
