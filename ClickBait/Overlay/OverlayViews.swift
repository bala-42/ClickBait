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
    /// Degrees clockwise from vertex-up.
    var angle: Double = Self.restingAngle
    static let size: CGFloat = 15
    /// Up-left, at the cursor.
    static let restingAngle: Double = -45

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = false

    var body: some View {
        EquilateralTriangle()
            .fill(tone.color.opacity(0.9))
            .overlay(EquilateralTriangle().stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)))
            .frame(width: Self.size, height: Self.size)
            .rotationEffect(.degrees(angle))
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: angle)
            .shadow(color: tone.color.opacity(pulsing && beat ? 0.9 : 0.45), radius: pulsing && beat ? 7 : 3)
            .scaleEffect(pulsing && beat && !reduceMotion ? 1.18 : 1)
            .opacity(pulsing && beat && reduceMotion ? 0.6 : 1)
            .frame(width: Self.size * 1.7, height: Self.size * 1.7)
            .animation(.easeInOut(duration: 0.25), value: tone)
            .onAppear { beat = true }
            .animation(pulsing ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: beat)
            .onChange(of: pulsing) { _, isPulsing in
                // Restart the beat so the repeat animation picks up the new state.
                beat = false
                if isPulsing { DispatchQueue.main.async { beat = true } }
            }
            .accessibilityHidden(true)
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
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .modifier(GlassBackground(shape: Capsule()))
                    .accessibilityLabel("ClickBait is pointing at \(label)")
            }
        }
        .padding(6)  // room for the glass shadow
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.guideLabelSize = $0 }
        .frame(width: OverlayModel.guideLabelCanvas.width, height: OverlayModel.guideLabelCanvas.height, alignment: .topLeading)
    }
}

/// The companion that follows the cursor: the triangle, with a card beside it when
/// there's something to say — both in the same state colour.
struct CompanionBubbleView: View {
    let model: OverlayModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let maxTextWidth: CGFloat = 300

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            CompanionTriangle(tone: model.tone, pulsing: model.isPulsing, angle: model.triangleAngle)
                .padding(2)
            if model.bubble != .idle && !model.isGuiding {
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

    @ViewBuilder private var card: some View {
        let tint = model.tone.color
        switch model.bubble {
        case .idle:
            EmptyView()
        case .explaining(let excerpt):
            BubbleCard(symbol: "text.magnifyingglass", tint: tint, title: "Explaining", message: Self.quote(excerpt),
                       showsSpinner: true)
        case .listening:
            BubbleCard(symbol: "mic.fill", tint: tint, title: "Listening", message: "Let go of ⌃⌥ when you're done.")
        case .thinking(let heard):
            BubbleCard(symbol: "sparkles", tint: tint, title: "Thinking", message: heard.map { "“\($0)”" },
                       showsSpinner: true)
        case .answer(let text):
            BubbleCard(symbol: "cursorarrow.rays", tint: tint, title: "ClickBait", message: text)
        case .working(let message):
            BubbleCard(symbol: "gearshape.fill", tint: tint, title: "Working", message: message, showsSpinner: true)
        case .done(let message):
            BubbleCard(symbol: "checkmark", tint: tint, title: "Done", message: message)
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
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
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
                .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        }
    }
}
