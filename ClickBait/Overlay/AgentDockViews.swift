import ClickBaitCore
import SwiftUI

/// Background ClickBaits drawn as HeyClicky's agent dock (`AgentDock` holds the sizes):
/// a column of dark tiles top-right, a card hanging under a clicked tile, and a result pill
/// at the cursor when one finishes. These views only draw; `CapsuleController` places them.

/// The dock's colours: its dots are ClickBait's own (Azure working, `CompanionTone.idle`;
/// done in the chat's Aqua green, `AquaDark.aquaGreen` — its "Copied ✓" — never Shamrock,
/// which means a Mac action), grey failed or stopped; plus the tiles' and card's glass.
enum AgentDockStyle {
    static let tileFill = Color(red: 0.15, green: 0.16, blue: 0.165).opacity(0.9)
    static let cardFill = Color(red: 0.11, green: 0.12, blue: 0.12).opacity(0.84)
    static let hairline = Color.white.opacity(0.1)
    static let title = Color.white.opacity(0.93)
    static let secondary = Color(red: 0.68, green: 0.71, blue: 0.70)
    static let tertiary = Color(red: 0.42, green: 0.45, blue: 0.44)
    static let pillFill = Color.white.opacity(0.07)

    static func dot(_ dot: AgentDock.Dot) -> Color {
        switch dot {
        case .azure: CompanionTone.idle.color
        case .aquaGreen: AquaDark.aquaGreen
        case .grey: Color(white: 0.55)
        }
    }
}

/// One job's tile: a dark rounded square glowing in the job's colour, its triangle inside,
/// a status dot top-right.
struct AgentTile: View {
    let tone: CompanionTone
    let look: AgentDock.Look
    /// The triangle's angle, degrees (renders show a spin mid-turn).
    var angle: Double = 0
    /// Working: the companion's turn-a-third spin (a gentle pulse with Reduce Motion), from
    /// its cached drawing.
    var spinning = false
    /// The pulse's swell, 0…1 (done, or working with Reduce Motion).
    var beat: Double = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AgentDock.tileCorner, style: .continuous)
        ZStack {
            shape.fill(AgentDockStyle.tileFill)
            shape.strokeBorder(AgentDockStyle.hairline, lineWidth: 0.5)
            CompanionTriangle(tone: tone, pulsing: false, spinning: spinning, angle: angle,
                              glowOpacity: Glow.opacity, glowRadius: Glow.radius)
                .scaleEffect(AgentDock.triangleSize / CompanionTriangle.size)
            Circle().fill(AgentDockStyle.dot(look.dot))
                .frame(width: AgentDock.dotDiameter, height: AgentDock.dotDiameter)
                .position(x: AgentDock.tileSize - AgentDock.dotInset, y: AgentDock.dotInset)
        }
        .frame(width: AgentDock.tileSize, height: AgentDock.tileSize)
        .background { Self.glow(tone).opacity(0.5 + 0.35 * beat) }
        .opacity(look.dimmed ? 0.55 : 1)
        .saturation(look.dimmed ? 0.3 : 1)
    }
}

extension AgentTile {
    /// The tile's glow, blurred once into a cached texture: a pulse only fades it (an
    /// animated blur or shadow radius re-blurs every frame).
    static func glow(_ tone: CompanionTone) -> some View {
        RoundedRectangle(cornerRadius: AgentDock.tileCorner, style: .continuous)
            .fill(tone.color)
            .frame(width: AgentDock.tileSize, height: AgentDock.tileSize)
            .padding(CapsuleController.tileMargin)
            .blur(radius: 7)
            .drawingGroup()
            .frame(width: AgentDock.tileSize, height: AgentDock.tileSize)
    }
}

/// The card's glass: dark, see-through, a hairline edge and a glow in the job's colour.
private struct AgentCardChrome: ViewModifier {
    let tone: CompanionTone
    /// False in `ImageRenderer` renders, which can't draw a material.
    var blur = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AgentDock.cardCorner, style: .continuous)
        content
            .padding(.horizontal, AgentDock.cardSidePadding)
            .padding(.top, AgentDock.cardTopPadding)
            .padding(.bottom, 14)
            .frame(width: AgentDock.cardWidth, alignment: .leading)
            .background { shape.fill(tone.color.opacity(0.05)) }
            .background { shape.fill(AgentDockStyle.cardFill) }
            .background { if blur { shape.fill(.ultraThinMaterial) } }
            .overlay { shape.strokeBorder(AgentDockStyle.hairline, lineWidth: 0.6) }
            .background { shape.fill(tone.color.opacity(0.28)).blur(radius: 18) }
    }
}

/// UPPERCASE TITLE · [status] · ✕
private struct AgentCardTitle: View {
    let title: String
    let badge: String
    let tone: CompanionTone
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).kerning(0.4)
                .foregroundStyle(AgentDockStyle.title)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(badge)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tone.color)
                .padding(.horizontal, 7)
                .frame(minWidth: 36, minHeight: 15)
                .background(tone.color.opacity(0.16), in: Capsule())
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(AgentDockStyle.secondary)
                    .frame(width: 14, height: 14)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(badge == "running" ? "Stop" : "Close")
        }
    }
}

/// A working job: its title, the line the answer is writing now, and the progress bar.
struct AgentRunningCard: View {
    let title: String
    let liveLine: String
    let tone: CompanionTone
    let progressBar: AnyView
    var blur = true
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentCardTitle(title: title, badge: "running", tone: tone, onClose: onStop)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tone.color)
                    .frame(width: 14, height: 15)
                Text(liveLine)
                    .font(.system(size: 12))
                    .foregroundStyle(AgentDockStyle.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            progressBar.padding(.top, 6)
        }
        .modifier(AgentCardChrome(tone: tone, blur: blur))
    }
}

/// A finished job: its summary, up to two suggested next questions, follow up by text or
/// voice, and go there! / later, pls.
struct AgentDoneCard: View {
    let title: String
    let summary: String
    let suggestions: [String]
    let tone: CompanionTone
    var canGoThere = true
    var blur = true
    let onClose: () -> Void
    let onSuggestion: (String) -> Void
    let onFollowUpText: () -> Void
    let onFollowUpVoice: () -> Void
    let onGoThere: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentCardTitle(title: title, badge: "done", tone: tone, onClose: onClose)
            Text(summary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentDockStyle.title)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            if !suggestions.isEmpty {
                label("suggested next:").padding(.top, 12)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(suggestions.prefix(2), id: \.self) { suggestion in
                        pill(suggestion) { onSuggestion(suggestion) }
                    }
                }
                .padding(.top, 6)
            }
            label("follow up").padding(.top, 12)
            HStack(spacing: 6) {
                pill("text", symbol: "character.cursor.ibeam", action: onFollowUpText)
                pill("voice", symbol: "mic", action: onFollowUpVoice)
            }
            .padding(.top, 6)
            HStack(spacing: 8) {
                Spacer()
                pill("later, pls", action: onLater)
                Button(action: onGoThere) {
                    Text("go there!")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                        .background(tone.color.opacity(canGoThere ? 0.9 : 0.35), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canGoThere)
                .help(canGoThere ? "" : "Finish the current question first")
            }
            .padding(.top, 12)
        }
        .modifier(AgentCardChrome(tone: tone, blur: blur))
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(AgentDockStyle.tertiary)
    }

    private func pill(_ text: String, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .medium)) }
                Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(AgentDockStyle.title.opacity(0.88))
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(AgentDockStyle.pillFill, in: Capsule())
            .overlay(Capsule().strokeBorder(AgentDockStyle.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// A job that couldn't finish: why, and ✕ to remove it.
struct AgentFailedCard: View {
    let title: String
    let reason: String
    let tone: CompanionTone
    var blur = true
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentCardTitle(title: title, badge: "failed", tone: tone, onClose: onClose)
            Text("Couldn't answer: \(reason)")
                .font(.system(size: 12))
                .foregroundStyle(AgentDockStyle.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(AgentCardChrome(tone: tone, blur: blur))
    }
}

/// The result at the cursor when a job finishes: its summary in a pill of the job's colour.
struct AgentResultPill: View {
    let text: String
    let tone: CompanionTone

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: 330, alignment: .leading)
            .background(tone.color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(color: tone.color.opacity(Glow.opacity), radius: Glow.radius)
    }
}
