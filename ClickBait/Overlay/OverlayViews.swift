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

/// A pulsing ring on the target, an arrow aimed at it, and a label pill.
struct PointerView: View {
    let label: String
    let number: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var pulse = false

    private static let ringSize: CGFloat = 46
    private let accent = Color(red: 1.0, green: 0.27, blue: 0.42)

    var body: some View {
        ZStack {
            // Soft halo so the ring reads on light and dark backgrounds.
            Circle()
                .fill(accent.opacity(0.18))
                .frame(width: Self.ringSize, height: Self.ringSize)
                .scaleEffect(pulse ? 1.35 : 1.0)
                .opacity(pulse ? 0 : 1)

            Circle()
                .strokeBorder(accent, lineWidth: 4)
                .background(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 6).padding(-2))
                .frame(width: Self.ringSize, height: Self.ringSize)

            Arrow()
                .fill(accent)
                .overlay(Arrow().stroke(.white, lineWidth: 1.5))
                .frame(width: 28, height: 28)
                .rotationEffect(.degrees(135))  // up-pointing shape → aims down-right at the ring
                .offset(x: -Self.ringSize / 2 - 14, y: -Self.ringSize / 2 - 14)
                .offset(x: appeared || reduceMotion ? 0 : -40, y: appeared || reduceMotion ? 0 : -40)

            labelPill
                .fixedSize()
                .offset(y: Self.ringSize / 2 + 18)
        }
        .frame(width: 1, height: 1)  // position() centers the ring on the target point
        .scaleEffect(appeared || reduceMotion ? 1 : 0.4)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.6)) {
                appeared = true
            }
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false).delay(0.3)) {
                pulse = true
            }
        }
        .accessibilityElement()
        .accessibilityLabel("ClickBait is pointing at \(label)")
    }

    @ViewBuilder private var labelPill: some View {
        if !label.isEmpty || number != nil {
            HStack(spacing: 4) {
                if let number {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .frame(width: 16, height: 16)
                        .background(.white, in: Circle())
                        .foregroundStyle(accent)
                }
                if !label.isEmpty {
                    Text(label).font(.system(size: 13, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(accent, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
    }
}

/// An arrowhead pointing up; rotated to aim down-right at the target.
private struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY * 0.72))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The small companion that follows the cursor and shows what ClickBait is doing.
struct CompanionBubbleView: View {
    let model: OverlayModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    static let maxTextWidth: CGFloat = 280

    var body: some View {
        Group {
            switch model.bubble {
            case .idle:
                Circle()
                    .fill(Color.accentColor.opacity(0.55))
                    .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                    .frame(width: 9, height: 9)
                    .padding(3)
            case .listening:
                row(symbol: "mic.fill", tint: .red, text: "Listening…")
                    .scaleEffect(breathing && !reduceMotion ? 1.04 : 1)
            case .thinking(let heard):
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(heard.map { "“\($0)”" } ?? "Thinking…")
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Self.maxTextWidth, alignment: .leading)
                }
                .bubbleStyle()
            case .answer(let text):
                row(symbol: "cursorarrow.rays", tint: .accentColor, text: text)
            case .error(let message):
                row(symbol: "exclamationmark.triangle.fill", tint: .orange, text: message)
            }
        }
        .font(.system(size: 13))
        .fixedSize()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { breathing = true }
        }
        .accessibilityElement(children: .combine)
    }

    private func row(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.maxTextWidth, alignment: .leading)
        }
        .bubbleStyle()
    }
}

private extension View {
    func bubbleStyle() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .padding(8)  // room for the shadow inside the panel
    }
}
