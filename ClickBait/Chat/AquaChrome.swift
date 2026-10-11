import AppKit
import SwiftUI

/// The chat's look: classic Mac OS X Aqua (2001–2007: gel, highlights, faint pinstripes,
/// lozenge buttons) in the dark, on glass. Colours from Clicky's dark palette (MIT,
/// DesignSystem.swift). All static chrome: the fixed-size pieces (header bar, gel buttons)
/// are cached (`drawingGroup`); the body and wells, which resize as an answer streams in,
/// are cheap shapes drawn directly. Streaming text never redraws any of it beyond a resize.
enum AquaDark {
    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    static let tintTop = hex(0x1A1C1E)
    static let tintBottom = hex(0x121414)
    /// The tint's strength over the blur: today's 0.28 black, as graphite.
    static let tintOpacity = 0.34
    static let border = hex(0x373B39)
    static let strongBorder = hex(0x444947)
    static let textPrimary = hex(0xECEEED)
    static let textSecondary = hex(0xADB5B2)
    static let textTertiary = hex(0x6B736F)
    /// Links: a lighter Aqua blue, to read on dark glass.
    static let link = hex(0x7ABEFF)
    /// Aqua green, for success ticks ("Copied").
    static let aquaGreen = hex(0x5BD25B)
    static let corner: CGFloat = 14

    /// 1 px lines every 3 px at 3% white, tiled from a tiny image (one texture, no drawing).
    static let pinstripes: NSImage = {
        let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 3, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 4, bitsPerPixel: 32)!
        pixels.setColor(NSColor(white: 1, alpha: 0.03), atX: 0, y: 0)
        pixels.setColor(.clear, atX: 0, y: 1)
        pixels.setColor(.clear, atX: 0, y: 2)
        pixels.size = NSSize(width: 0.5, height: 1.5)  // 1 × 3 device pixels on a 2× screen
        let image = NSImage(size: pixels.size)
        image.addRepresentation(pixels)
        return image
    }()
}

/// The body's tint and pinstripes over the blur, with its border and top highlight.
struct AquaBody: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AquaDark.corner, style: .continuous)
        ZStack {
            LinearGradient(colors: [AquaDark.tintTop, AquaDark.tintBottom], startPoint: .top, endPoint: .bottom)
                .opacity(AquaDark.tintOpacity)
            Image(nsImage: AquaDark.pinstripes)
                .resizable(resizingMode: .tile)
            // A thin inner highlight along the top edge, fading out within a few points.
            shape.inset(by: 0.8)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top,
                                             endPoint: UnitPoint(x: 0.5, y: 0.06)), lineWidth: 1)
            shape.strokeBorder(contrast == .increased ? AquaDark.strongBorder : AquaDark.border.opacity(0.6), lineWidth: 0.8)
        }
        // Not cached: it resizes with every streamed line, and a cached drawing re-renders
        // whole at each new size; a gradient, a tiled image and two strokes draw cheaply.
        .allowsHitTesting(false)
    }
}

/// The header's gel bar: a graphite tint with the old title bars' curved sheen on its upper
/// half, and a hairline under it.
struct AquaHeaderBar: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .top) {
                LinearGradient(colors: [AquaDark.hex(0x2C302E).opacity(0.42), AquaDark.hex(0x1C1F1E).opacity(0.32)],
                               startPoint: .top, endPoint: .bottom)
                // The sheen: a wide ellipse whose lower edge curves across the bar's middle.
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    .frame(width: size.width * 1.5, height: size.height * 1.1)
                    .offset(y: -size.height * 0.58)
                VStack(spacing: 0) {
                    Spacer()
                    Rectangle().fill(.black.opacity(0.45)).frame(height: 0.5)
                    Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

/// Classic Aqua's own button colours (never ClickBait's state colours): a gel gradient top
/// to bottom, a darker rim, and a glow (none for graphite).
struct AquaPalette {
    var stops: [Color]
    var rim: Color
    var glow: Color?

    static let blue = AquaPalette(stops: [AquaDark.hex(0x8CC8FF), AquaDark.hex(0x3D8EEA), AquaDark.hex(0x1B5FD1)],
                                  rim: AquaDark.hex(0x164FAF), glow: AquaDark.hex(0x3D8EEA))
    static let red = AquaPalette(stops: [AquaDark.hex(0xFF8A80), AquaDark.hex(0xF2463E), AquaDark.hex(0xC7261F)],
                                 rim: AquaDark.hex(0x9E1C16), glow: nil)
    static let green = AquaPalette(stops: [AquaDark.hex(0x5BD25B), AquaDark.hex(0x2E9E36)],
                                   rim: AquaDark.hex(0x227A29), glow: nil)
    static let graphite = AquaPalette(stops: [AquaDark.hex(0x6B6F72), AquaDark.hex(0x3A3D40)],
                                      rim: AquaDark.hex(0x26282A), glow: nil)
}

/// A gel button face: the palette's gradient, a glossy white band over its upper half, a
/// darker rim, and a soft glow in its colour.
struct AquaGel<S: InsettableShape>: View {
    var palette: AquaPalette
    var shape: S
    var pressed = false

    var body: some View {
        ZStack {
            shape.fill(LinearGradient(colors: palette.stops, startPoint: .top, endPoint: .bottom))
            // A touch of light low down, as Aqua's gel caught it from inside.
            shape.fill(RadialGradient(colors: [.white.opacity(0.18), .clear], center: UnitPoint(x: 0.5, y: 0.95),
                                      startRadius: 0, endRadius: 14))
            // The gloss: a band over the upper half, inset from the edge.
            GeometryReader { proxy in
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(pressed ? 0.28 : 0.55), .white.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: proxy.size.width * 0.78, height: proxy.size.height * 0.48)
                    .offset(x: proxy.size.width * 0.11, y: proxy.size.height * 0.05)
            }
            shape.strokeBorder(palette.rim, lineWidth: 0.8)
        }
        .clipShape(shape)
        .drawingGroup()
        .shadow(color: palette.glow?.opacity(0.65) ?? .clear, radius: 5)
    }
}

/// Moves down 1 pt and dims its gloss while pressed.
struct AquaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.aquaPressed, configuration.isPressed)
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}

extension EnvironmentValues {
    @Entry var aquaPressed = false
}

/// A recessed well (the input field, a code block): darker than the body, still see-through,
/// with an inner shadow along its top so it looks pressed in.
struct AquaWell<S: InsettableShape>: View {
    var shape: S
    var darkness = 0.22
    var bordered = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            shape.fill(.black.opacity(darkness))
            shape.strokeBorder(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top,
                                              endPoint: UnitPoint(x: 0.5, y: 0.45)), lineWidth: 1.5)
            shape.strokeBorder(LinearGradient(colors: [.clear, .white.opacity(0.06)], startPoint: UnitPoint(x: 0.5, y: 0.6),
                                              endPoint: .bottom), lineWidth: 1)
            if bordered {
                shape.strokeBorder(contrast == .increased ? AquaDark.strongBorder : AquaDark.border.opacity(0.6), lineWidth: 0.8)
            }
        }
        .allowsHitTesting(false)
    }
}
