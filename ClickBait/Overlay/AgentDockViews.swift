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
                .inkCentred(badge, size: 10)
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
    /// The mini-chat, when it's open (`FollowUpPanelView`): it stays while a follow-up runs.
    var footer: AnyView?
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
            if let footer { footer.padding(.top, 2) }
        }
        .modifier(AgentCardChrome(tone: tone, blur: blur))
    }
}

/// A done card's answer, whole: prose and code (with Copy), scrolling inside the card past
/// `maxHeight` so a long answer never fills the screen; a short one stays compact.
struct AgentAnswerBody: View {
    let text: String
    static let maxHeight: CGFloat = 260
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        Group {
            if contentHeight > Self.maxHeight {
                ScrollView(.vertical) { content }
                    .frame(height: Self.maxHeight)
            } else {
                content
            }
        }
        // Measured at its natural height, unseen, so it's known whether it needs to scroll.
        .background(alignment: .top) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MessageFormat.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let prose):
                    // Inline markdown (bold, italics, `code`, links), as in the chat.
                    Text((try? AttributedString(markdown: prose, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                        ?? AttributedString(prose))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AgentDockStyle.title)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(_, let code):
                    AgentCodeSnippet(code: code)
                }
            }
        }
    }
}

/// Code in a done card: monospaced, selectable, with a Copy button.
private struct AgentCodeSnippet: View {
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(code)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(AgentDockStyle.title)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            .buttonStyle(AquaButtonStyle(selected: copied))
            .accessibilityLabel(copied ? "Copied" : "Copy code")
        }
        .padding(8)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A finished job: its summary, up to two suggested next questions, follow up by text or
/// voice, and go there! / later, pls.
struct AgentDoneCard: View {
    let title: String
    let summary: String
    /// The whole answer (user's rule, 2026-10-20: a proper answer isn't cut off on the card);
    /// empty shows `summary`.
    var answer = ""
    let suggestions: [String]
    let tone: CompanionTone
    var canGoThere = true
    var blur = true
    let onClose: () -> Void
    let onSuggestion: (String) -> Void
    /// The mini-chat under the card (`FollowUpPanel`): its state and what the card asks of it.
    var followUp = FollowUpPanel()
    var onFollowUp: (FollowUpAction) -> Void = { _ in }
    var microphoneLevel: () -> Float = { 0 }
    /// The open mini-chat with its conversation (`FollowUpPanelView`).
    var footer: AnyView?
    let onGoThere: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentCardTitle(title: title, badge: "done", tone: tone, onClose: onClose)
            AgentAnswerBody(text: answer.isEmpty ? summary : answer)
                .padding(.top, 10)
            if !suggestions.isEmpty {
                label("suggested next:").padding(.top, 12)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(suggestions.prefix(MorningCards.maxCount), id: \.self) { suggestion in  // follow-ups send 2 at most
                        pill(suggestion) { onSuggestion(suggestion) }
                    }
                }
                .padding(.top, 6)
            }
            label("follow up").padding(.top, 12)
            HStack(spacing: 6) {
                Button { onFollowUp(.tap(.text)) } label: { Label("text", systemImage: "character.cursor.ibeam") }
                    .buttonStyle(AquaButtonStyle(selected: followUp.isOpen && !followUp.voice.isBusy))
                    .accessibilityLabel("Follow up by typing")
                VoiceButton(voice: followUp.voice, level: microphoneLevel) { onFollowUp(.tap(.voice)) }
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
            // Below everything else, so opening it moves nothing above it.
            if followUp.isOpen, let footer {
                footer
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: followUp.isOpen)
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
                    .inkCentred(text, size: 11, weight: .medium)
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

/// What the folded dock's handle shows: its colour (`DockCollapse.handleDot`) and how many
/// ClickBaits are waiting behind it, for VoiceOver.
@MainActor @Observable
final class DockHandleModel {
    var dot: AgentDock.Dot = .grey
    var count = 0
}

/// The folded dock: a slim pill against the screen's right edge. A click (or a shake over
/// it, watched by `CapsuleController`) brings the dock back.
struct DockHandleView: View {
    let model: DockHandleModel
    let onSummon: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSummon) {
            Capsule()
                .fill(AgentDockStyle.dot(model.dot))
                .frame(width: DockCollapse.handleWidth, height: DockCollapse.handleHeight)
                .opacity(hovering ? 1 : DockCollapse.handleRestOpacity)
                .padding(DockCollapse.handleHitMargin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Show background ClickBaits (click, or shake the pointer here)")
        .accessibilityLabel("Show background ClickBaits")
        .accessibilityValue("\(model.count) waiting")
    }
}

/// What a card's mini-chat asks of the app.
enum FollowUpAction {
    case tap(FollowUpPanel.Mode)
    case collapse
    case draft(String)
    case submit
}

/// The card's mini-chat: the follow-ups so far, then one input row — a field, the voice
/// button (the waveform while recording) and send — always both ways in. Return sends,
/// Escape folds it. Focus order: field, voice, send, fold.
struct FollowUpPanelView: View {
    let panel: FollowUpPanel
    /// The follow-ups so far (after the card's first question and answer).
    var thread: [ChatModel.Message] = []
    /// A follow-up is being answered: what it has said so far.
    var answering = false
    var liveLine = ""
    /// The card microphone's loudness (RMS) while recording, for the waveform.
    var microphoneLevel: () -> Float = { 0 }
    let onAction: (FollowUpAction) -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !thread.isEmpty || answering { FollowUpThread(messages: thread, answering: answering, liveLine: liveLine) }
            HStack(spacing: 6) {
                TextField(placeholder, text: Binding(get: { panel.draft }, set: { onAction(.draft($0)) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(AgentDockStyle.title)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AgentDockStyle.hairline, lineWidth: 0.5))
                    .focused($fieldFocused)
                    .onSubmit { onAction(.submit) }
                    .accessibilityLabel("Follow-up question")
                    .accessibilityHint("Type, or press voice and speak; your words land here to edit before sending")
                    .onAppear { fieldFocused = true }
                VoiceButton(voice: panel.voice, level: microphoneLevel, compact: true) { onAction(.tap(.voice)) }
                Button { onAction(.submit) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(AquaButtonStyle(compact: true))
                    .disabled(!panel.canSend || answering)
                    .accessibilityLabel("Send follow-up")
                Button { onAction(.collapse) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(AquaButtonStyle(compact: true))
                    .accessibilityLabel("Fold the follow-up chat")
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentDockStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(note)
            }
        }
        .onExitCommand { onAction(.collapse) }
        // A transcript just landed in the field: back to it, to edit or send.
        .onChange(of: panel.voice) { _, voice in if voice == .ready { fieldFocused = true } }
    }

    private var placeholder: String {
        switch panel.voice {
        case .recording: "listening…"
        case .transcribing: "working out what you said…"
        default: answering ? "answering…" : "Ask a follow-up…"
        }
    }

    private var note: String? {
        if case .failed(let reason) = panel.voice { return reason }
        if panel.voice == .recording { return "Press voice again to stop; your words land in the field." }
        return panel.hint
    }
}

/// The voice button: a mic; while recording, the companion's waveform inside it (Clicky's
/// bars, `WaveformMeter`, MIT) following the card microphone; a spinner while transcribing.
/// One press starts, the next stops.
struct VoiceButton: View {
    let voice: FollowUpPanel.Voice
    let level: () -> Float
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                switch voice {
                case .recording:
                    CardWaveform(level: level)
                case .transcribing, .starting:
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                case .ready, .failed:
                    Image(systemName: "mic")
                }
                if !compact { Text(voice == .recording ? "stop" : "voice") }
            }
        }
        .buttonStyle(AquaButtonStyle(selected: voice == .recording))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(voice == .recording ? .isSelected : [])
    }

    private var accessibilityLabel: String {
        switch voice {
        case .recording: "Stop recording"
        case .starting: "Starting the microphone"
        case .transcribing: "Working out what you said"
        case .ready, .failed: "Follow up by voice"
        }
    }
}

/// The mini-chat's conversation: questions on the right, answers on the left, newest at the
/// bottom, scrolled to it; at most ~150 pt tall. Text is selectable.
private struct FollowUpThread: View {
    let messages: [ChatModel.Message]
    let answering: Bool
    let liveLine: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(messages) { message in
                        bubble(message.text, fromUser: message.role == .user).id(message.id)
                    }
                    if answering {
                        bubble(liveLine.isEmpty ? "…" : liveLine + " …", fromUser: false).id("live")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: liveLine) { _, _ in scrollToEnd(proxy) }
        }
        .accessibilityLabel("Follow-up conversation")
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if answering { proxy.scrollTo("live", anchor: .bottom) } else if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private func bubble(_ text: String, fromUser: Bool) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(fromUser ? AgentDockStyle.title : AgentDockStyle.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.white.opacity(fromUser ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: fromUser ? .trailing : .leading)
            .accessibilityLabel((fromUser ? "You: " : "ClickBait: ") + text)
    }
}

private extension Text {
    func voiceStatus() -> some View {
        font(.system(size: 11, weight: .medium)).foregroundStyle(AgentDockStyle.secondary).lineLimit(1)
    }
}

/// The voice button's waveform: the companion's listening bars (`WaveformMeter`, Clicky's,
/// MIT), black on the light-blue button, following the card microphone. Reduce Motion: no
/// idle pulse.
private struct CardWaveform: View {
    let level: () -> Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var meter = Meter()

    /// The bars' envelope, kept between frames without redrawing the card.
    private final class Meter {
        var envelope = 0.0
        var last: Date?
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let dt = meter.last.map { context.date.timeIntervalSince($0) } ?? 0
            let _ = { meter.last = context.date; meter.envelope = WaveformMeter.level(after: meter.envelope, rms: Double(level()), dt: dt) }()
            HStack(alignment: .center, spacing: WaveformMeter.barSpacing) {
                ForEach(WaveformMeter.barProfile.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: WaveformMeter.barCornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.85))
                        .frame(width: WaveformMeter.barWidth,
                               height: WaveformMeter.barHeight(index: index, level: meter.envelope, time: time,
                                                               pulsing: !reduceMotion))
                }
            }
        }
        .frame(width: 22, height: 14)
        .accessibilityHidden(true)  // the button says it
    }
}

/// Classic macOS Aqua gel buttons, light blue with black text and icons (user's request,
/// 2026-10-14, after HeyClicky's card buttons): a vertical blue gradient, a white gloss on the
/// top half, a darker rim. Selected (its panel open) is a deeper blue; pressed darkens it.
struct AquaButtonStyle: ButtonStyle {
    var selected = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    static let top = Color(red: 0.82, green: 0.92, blue: 0.99)
    static let bottom = Color(red: 0.61, green: 0.79, blue: 0.92)
    static let rim = Color(red: 0.36, green: 0.57, blue: 0.73)

    func makeBody(configuration: Configuration) -> some View {
        let deep = selected || configuration.isPressed
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.black.opacity(isEnabled ? 0.9 : 0.4))
            .padding(.horizontal, compact ? 6 : 10)
            .frame(height: 20)
            .background {
                ZStack {
                    Capsule().fill(LinearGradient(colors: [Self.top, Self.bottom], startPoint: .top, endPoint: .bottom))
                    Capsule().fill(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.06)],
                                                  startPoint: .top, endPoint: .center))
                        .padding(.horizontal, 3).padding(.top, 1).padding(.bottom, 11)
                }
                .brightness(deep ? -0.06 : 0)
                .saturation(isEnabled ? 1 : 0.4)
            }
            .overlay(Capsule().strokeBorder(Self.rim.opacity(0.58), lineWidth: 0.7))
            .shadow(color: Self.rim.opacity(deep ? 0.05 : 0.12), radius: 2, x: 0, y: 1)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: deep)
    }
}
