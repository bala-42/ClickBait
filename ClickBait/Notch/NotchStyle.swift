import AppKit
import SwiftUI

// The notch look (user's choice, 2026-10-20): palette, cards, header tabs and player controls,
// adapted from MIT-licensed code (© 2026 Louis Raillé — see THIRD_PARTY_NOTICES.md). State
// colours stay ClickBait's (`CompanionTone`).

/// The notch's one palette: greys from lightest text to the card fill, then the few colours
/// that aren't states (states are `CompanionTone`; problems `CompanionTone.problem`).
enum NotchPalette {
    static let text = Color(hex: 0xF5F6F8)
    static let secondary = Color(hex: 0x8E939C)
    /// Lifted from #6B7079 (about 3.8:1 on the cards) to read at small sizes: about 5:1.
    static let tertiary = Color(hex: 0x878C95)
    static let hover = Color(hex: 0xB0B5BE)
    static let control = Color(hex: 0xC5C8CD)
    static let card = Color(hex: 0x141518)
    /// The four squares' names: one dark grey on their coloured shades.
    static let pillText = Color(hex: 0x24262B)
    static let tabOn = Color(hex: 0x1D1F23)
    static let ink = Color(hex: 0x0E0F11)
    /// The shelf's drop targets, selection and note focus.
    static let highlight = Color(red: 0.65, green: 0.78, blue: 0.95)
    /// A gauge's empty track (the volume HUD).
    static let track = Color.white.opacity(0.14)
    /// Music bars and accents when the artwork gives no colour.
    static let music = Color(red: 0.55, green: 0.62, blue: 0.92)
    /// The Music panel's accent: pastel bubblegum violet (user's pick, 2026-10-23).
    static let bubblegum = Color(hex: 0xF2A9DC)
    /// The home pills, as the glossy Windows 7 logo's squares (user's reference, 2026-10-23):
    /// each pill's colour, and its square's shading, top-leading to bottom-trailing.
    static let windowsRed = Color(hex: 0xEE4422)
    static let windowsGreen = Color(hex: 0x7CB82F)
    static let windowsBlue = Color(hex: 0x3A86C8)
    static let windowsYellow = Color(hex: 0xFFC21A)

    static func windowsShade(_ tint: Color) -> [Color]? {
        switch tint {
        case windowsRed: [Color(hex: 0xD9261C), Color(hex: 0xF07A1E), Color(hex: 0xF7C531)]
        case windowsGreen: [Color(hex: 0xB9DE7A), Color(hex: 0x6DAE2A), Color(hex: 0x2F7A1C)]
        case windowsBlue: [Color(hex: 0x1F4FA0), Color(hex: 0x3F86C6), Color(hex: 0xB5DDF0)]
        case windowsYellow: [Color(hex: 0xFFE05A), Color(hex: 0xFFC21A), Color(hex: 0xF39019)]
        default: nil
        }
    }

    /// The artwork's colour, lifted towards white so it reads on black.
    static func lifted(_ color: NSColor?, _ amount: CGFloat, fallback: Color) -> Color {
        guard let base = color?.usingColorSpace(.deviceRGB) else { return fallback }
        return Color(nsColor: base.blended(withFraction: amount, of: .white) ?? base)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A card: near-black, corner 20, a hairline, and an optional soft wash of colour rising from
/// below (a ClickBait tone when the card is about a state).
struct NotchCard: ViewModifier {
    var wash: Color?
    var corner: CGFloat = Look.Corner.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        content
            .background {
                shape.fill(NotchPalette.card)
                    .overlay {
                        if let wash {
                            RadialGradient(stops: [.init(color: wash, location: 0), .init(color: .clear, location: 0.7)],
                                           center: UnitPoint(x: 0.5, y: 1.3), startRadius: 0, endRadius: 280)
                                .clipShape(shape)
                        }
                    }
                    .overlay(shape.stroke(Color.white.opacity(0.035), lineWidth: 1))
            }
    }
}

extension View {
    func notchCard(wash: Color? = nil, corner: CGFloat = Look.Corner.card) -> some View {
        modifier(NotchCard(wash: wash, corner: corner))
    }
}

// MARK: - Header

/// A plain header icon: grey, white on hover or when on.
struct NotchHeaderIcon: View {
    let symbol: String
    let label: String
    var on = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(on || hovering ? NotchPalette.text : NotchPalette.secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Player

/// A thin slider: grey track, light fill; on hover or drag it thickens, takes the accent and
/// grows a knob. Click or drag anywhere on it.
struct PlayerBar: View {
    let fraction: Double
    let accent: Color
    let enabled: Bool
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let filled = min(1, max(0, fraction))
            let active = enabled && (hovering || dragging)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: active ? 4 : 3)
                Capsule().fill(active ? accent : NotchPalette.control).frame(width: width * filled, height: active ? 4 : 3)
                if active {
                    Circle().fill(NotchPalette.text).frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: min(width - 9, max(0, width * filled - 4.5)))
                }
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .onHover { hover in withAnimation(.easeOut(duration: 0.12)) { hovering = hover } }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard enabled else { return }
                    dragging = true
                    onChange(min(1, max(0, drag.location.x / width)))
                }
                .onEnded { drag in
                    guard enabled else { return }
                    dragging = false
                    onCommit(min(1, max(0, drag.location.x / width)))
                })
        }
    }
}

/// Elapsed time, the bar, time left; dragging shows where it will land before it seeks.
struct PlayerProgress: View {
    let position: Double
    let duration: Double
    let accent: Color
    let onSeek: (Double) -> Void
    @State private var dragFraction: Double?

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        return duration > 0 ? min(1, max(0, position / duration)) : 0
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(Self.format(fraction * duration)).frame(minWidth: 26, alignment: .trailing)
            PlayerBar(fraction: fraction, accent: accent, enabled: duration > 0,
                      onChange: { dragFraction = $0 },
                      onCommit: { onSeek($0 * duration); dragFraction = nil })
                .frame(height: 10)
                .accessibilityElement()
                .accessibilityLabel("Position")
                .accessibilityValue("\(Self.format(fraction * duration)) of \(Self.format(duration))")
            Text(duration > 0 ? "-" + Self.format(max(0, duration - fraction * duration)) : "")
                .frame(minWidth: 28, alignment: .leading)
        }
        .font(.system(size: 9.5).monospacedDigit())
        .foregroundStyle(NotchPalette.tertiary)
    }

    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The player's own volume: a speaker that shows the level and a short bar.
struct PlayerVolume: View {
    let volume: Int
    let accent: Color
    let onChange: (Int) -> Void

    var body: some View {
        let symbol = volume == 0 ? "speaker.slash.fill" : volume < 34 ? "speaker.wave.1.fill"
            : volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(NotchPalette.tertiary)
                .frame(width: 13, alignment: .trailing)
            PlayerBar(fraction: Double(volume) / 100, accent: accent, enabled: true,
                      onChange: { onChange(Int(($0 * 100).rounded())) },
                      onCommit: { onChange(Int(($0 * 100).rounded())) })
                .frame(width: 44, height: 10)
        }
        .help("Volume \(volume)%")
        .accessibilityElement()
        .accessibilityLabel("Player volume")
        .accessibilityValue("\(volume) percent")
        .accessibilityAdjustableAction { direction in
            onChange(min(100, max(0, volume + (direction == .increment ? 10 : -10))))
        }
    }
}

struct PlayerIconButton: View {
    let symbol: String
    let size: CGFloat
    let tint: Color
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hovering ? NotchPalette.text : tint)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .onHover { hover in withAnimation(.easeOut(duration: 0.12)) { hovering = hover } }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Look.Motion.press, value: configuration.isPressed)
    }
}
