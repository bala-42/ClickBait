import AppKit
import ClickBaitCore
import SwiftUI

/// The chat, in dark Aqua on glass (`AquaChrome.swift`): a see-through, blurred card with a
/// graphite tint, faint pinstripes and a gel header; each question small and grey with its
/// answer as the main text below, a recessed "Ask ClickBait…" capsule with a gel send
/// button, and a spring in from the companion's corner.
/// What's behind the chat, for renders only (Debug): `ImageRenderer` can't draw the
/// window-server blur, so a render blurs this picture instead, the same for every look.
struct ChatBackdrop {
    var image: NSImage
    /// Where the card's top-left sits on the picture, and the picture's size (pt).
    var origin: CGPoint
    var size: CGSize
}

extension EnvironmentValues {
    @Entry var chatBackdrop: ChatBackdrop?
    /// Renders only: show the close button hovered, and code blocks as just copied.
    @Entry var chatRenderHover = false
    @Entry var chatRenderCopied = false
}

struct ChatView: View {
    @Bindable var model: ChatModel
    /// The same chat inside the notch's Ask tab: filling it, on solid dark instead of glass,
    /// with no window to drag, grow or line up with the companion.
    var inNotch = false
    @Environment(\.chatBackdrop) private var backdrop
    @Environment(\.chatRenderHover) private var renderHover

    static let width: CGFloat = 520
    static let corner: CGFloat = AquaDark.corner
    nonisolated static let cardSpace = "chatCard"
    /// Header layout, shared with ChatController so the logo can open exactly on the
    /// companion's triangle.
    private static let headerLeading: CGFloat = 16
    private static let headerTop: CGFloat = 12
    private static let headerRowHeight: CGFloat = 20
    /// The logo's centre, measured from the card's top-left (y down).
    static var logoCenter: CGPoint {
        CGPoint(x: headerLeading + headerRowHeight / 2, y: headerTop + headerRowHeight / 2)
    }
    private static let maxTranscriptHeight: CGFloat = 380
    @State private var transcriptHeight: CGFloat = 0
    @State private var shown = false
    @State private var closeHovered = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if inNotch {
            VStack(spacing: 0) {
                header
                transcript.frame(maxHeight: .infinity, alignment: .top)
                inputRow
            }
            // The notch's own card, as Home and Settings wear it: no gel, glass or pinstripes.
            .notchCard()
            .tint(AquaDark.link)
            .clipShape(RoundedRectangle(cornerRadius: Look.Corner.card, style: .continuous))
            .environment(\.colorScheme, .dark)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        VStack(spacing: 0) {
            header
            // Nothing asked yet (a chat opened to type into): no empty space above the field.
            if !model.messages.isEmpty || model.isBusy { transcript }
            inputRow
        }
        .frame(width: Self.width)
        .coordinateSpace(.named(Self.cardSpace))
        // Empty parts of the card drag the window (SwiftUI content would otherwise
        // swallow the mouse-down before the window could move).
        .background { if backdrop == nil { WindowDragArea() } }
        // A dark, blurred, see-through panel (the macOS heads-up material) in dark Aqua.
        .background(SiriPanel())
        .tint(AquaDark.link)  // links
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .environment(\.colorScheme, .dark)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.cardSize = $0 }
        // Grows out of the companion, and shrinks back into it.
        // Grows from half size at the companion; the fade is the window's (animated by the
        // window server, smooth even while ClickBait is busy). Scaling the whole blurred card
        // up from 8% redrew too much per frame and stuttered.
        .scaleEffect((shown || backdrop != nil) && !model.isClosing && !model.isTucked ? 1 : (reduceMotion ? 1 : 0.5),
                     anchor: model.companionAnchor)
        .onAppear {
            // A beat later: the card has measured itself and knows where the companion is.
            DispatchQueue.main.async {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Look.Motion.reveal) { shown = true }
            }
        }
        .animation(.easeIn(duration: 0.18), value: model.isClosing)
        // Tucks away quickly; comes back with the same spring it opened with.
        .animation(model.isTucked ? .easeIn(duration: 0.18)
                   : (reduceMotion ? .easeOut(duration: 0.15) : Look.Motion.reveal),
                   value: model.isTucked)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.isFlipped {
                closeButton
                keepButtons
                Spacer()
                title
                logo
            } else {
                logo
                title
                Spacer()
                keepButtons
                closeButton
            }
        }
        .frame(height: Self.headerRowHeight)
        .padding(.horizontal, Self.headerLeading)
        .padding(.top, Self.headerTop)
        .padding(.bottom, 4)
        // The gel bar sits behind the header only; the logo's place is unchanged.
        .background { if !inNotch { AquaHeaderBar() } }
    }

    private var logo: some View {
        // The pearl bean (user's choice, 2026-10-23), glowing orange while answering as the
        // companion does; its centre is where the chat lines up with the companion.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.isBusy)) { timeline in
            BeanFace(mood: model.isBusy ? .thinking : .idle, eyes: model.isBusy ? Bean.eyePairs(for: .thinking)[0] : .both(.pill()),
                     size: 19, time: model.isBusy ? timeline.date.timeIntervalSinceReferenceDate : 0, badge: false)
        }
            .frame(width: Self.headerRowHeight, height: Self.headerRowHeight)
            // Measured, not assumed: the chat places itself so this point is on the companion.
            .onGeometryChange(for: CGPoint.self) { proxy in
                let frame = proxy.frame(in: .named(Self.cardSpace))
                return CGPoint(x: frame.midX, y: frame.midY)
            } action: { if !inNotch { model.logoOffset = $0 } }  // the bubble's window lines up on it
    }

    private var title: some View {
        Text("ClickBait")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(inNotch ? NotchPalette.secondary : AquaDark.textSecondary)
            .shadow(color: .black.opacity(inNotch ? 0 : 0.5), radius: 0, y: -0.5)  // Aqua's engraved title
    }

    /// Remember a line from this answer, or save the whole chat as a file (C5).
    @ViewBuilder private var keepButtons: some View {
        if let note = model.keptNote {
            Text(note)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AquaDark.textSecondary)
                .transition(.opacity)
        } else if model.canKeep {
            HStack(spacing: 10) {
                Button { model.onRemember?() } label: { Image(systemName: "brain") }
                    .help("Remember a line from this answer")
                    .accessibilityLabel("Remember a line from this answer")
                Button { model.onSaveAnswer?() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Save this answer as a file")
                    .accessibilityLabel("Save this answer as a file")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AquaDark.textSecondary)
            .transition(.opacity)
        }
    }

    @ViewBuilder private var closeButton: some View {
        if inNotch {
            if model.offersLook {
                NotchHeaderIcon(symbol: model.looksAtScreen ? "eye.fill" : "eye", label: model.looksAtScreen
                                ? "Your screen goes with the next message" : "Look at my screen with the next message") {
                    model.looksAtScreen.toggle()
                }
                .help(model.looksAtScreen ? "Your screen goes with the next message" : "Look at my screen with the next message")
            }
            if let clear = model.onClear, !model.messages.isEmpty {
                // A fresh start, not deleting anything: a refresh arrow (user's pick, 2026-11-02).
                NotchHeaderIcon(symbol: "arrow.clockwise", label: "New chat") { clear() }.help("New chat")
            }
            NotchHeaderIcon(symbol: "xmark", label: "Put the chat away") { model.onClose?() }
        } else {
            gelCloseButton
        }
    }

    private var gelCloseButton: some View {
        Button {
            model.onClose?()
        } label: {
            // A small graphite gel button; its ✕ shows on hover, like Aqua's window buttons.
            CloseGel(hovering: closeHovered || renderHover)
        }
        .buttonStyle(AquaPressStyle())
        .onHover { closeHovered = $0 }
        .help("Close (Esc)")
        .accessibilityLabel("Close chat")
    }

    @ViewBuilder private var transcript: some View {
        if backdrop != nil {
            // A render: no AppKit scroll view (ImageRenderer can't draw one).
            transcriptContent
        } else {
            scrollingTranscript
        }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.messages) { message in
                MessageRow(message: message).id(message.id).environment(\.resultsInNotch, inNotch)
            }
            if model.isBusy, model.messages.last?.role != .assistant {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").font(.system(size: 15)).foregroundStyle(AquaDark.textTertiary)
                }
                .id("busy")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var scrollingTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.messages) { message in
                        MessageRow(message: message).id(message.id).environment(\.resultsInNotch, inNotch)
                    }
                    if model.isBusy, model.messages.last?.role != .assistant {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(.system(size: 15)).foregroundStyle(.secondary)
                        }
                        .id("busy")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { transcriptHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: inNotch ? nil : min(transcriptHeight, Self.maxTranscriptHeight))
            .onChange(of: model.messages) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(model.messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private var inputRow: some View {
        // Centred: aligned at the bottom, the taller send button left a gap above the text.
        HStack(alignment: .center, spacing: 8) {
            if backdrop != nil {
                // A render: the field's words as text (ImageRenderer can't draw AppKit fields).
                Text(model.draft.isEmpty ? placeholder : model.draft)
                    .font(.system(size: 14))
                    .foregroundStyle(model.draft.isEmpty ? AquaDark.textTertiary : AquaDark.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $model.draft,
                          prompt: Text(placeholder).foregroundStyle(AquaDark.textTertiary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(AquaDark.textPrimary)
                    .accessibilityLabel(placeholder)
                    .lineLimit(1...4)
                    .focused($fieldFocused)
                    .onSubmit { model.send() }
                    .onChange(of: model.focusRequest) { _, _ in fieldFocused = true }
                    .onAppear { if model.focusRequest > 0 { fieldFocused = true } }
            }
            Button {
                model.send()
            } label: {
                // Aqua blue whenever it can send; graphite, without a glow, while there's
                // nothing to send or an answer is still coming. Never the companion's colours.
                if inNotch {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Color.black : NotchPalette.tertiary)
                        .frame(width: 26, height: 26)
                        .background(canSend ? AquaDark.link : NotchPalette.tabOn, in: Circle())
                } else {
                    SendGel(palette: canSend ? .blue : .graphite)
                }
            }
            .buttonStyle(AquaPressStyle())
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        // A recessed capsule, pressed into the glass.
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background {
            let field = RoundedRectangle(cornerRadius: 18, style: .continuous)
            if inNotch {
                field.fill(NotchPalette.ink).overlay(field.stroke(Color.white.opacity(0.08), lineWidth: 1))
            } else {
                AquaWell(shape: field)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var placeholder: String {
        // Lookup's note: "find …" searches this Mac (user's ask, 2026-11-02).
        if inNotch { return model.messages.isEmpty ? "Ask, or type “find …” to look something up" : "Follow up, or “find …” to look something up" }
        return model.messages.isEmpty ? "Ask ClickBait…" : "Ask a follow-up…"
    }

    private var canSend: Bool {
        !model.isBusy && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct MessageRow: View {
    let message: ChatModel.Message
    @Environment(\.colorSchemeContrast) private var contrast

    /// Tidied markdown blocks plus inline markdown (bold, italics, `code`, links); line breaks kept.
    static func markdown(_ text: String) -> AttributedString { MessageFormat.attributedProse(text) }

    var body: some View {
        switch message.role {
        case .user:
            // What was asked: small and grey, the answer below is the main text.
            Text(message.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(contrast == .increased ? AquaDark.textPrimary : AquaDark.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 6)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(MessageFormat.segments(message.text).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let prose):
                        Text(Self.markdown(prose))
                            .font(.system(size: 15.5, weight: contrast == .increased ? .medium : .regular))
                            .foregroundStyle(contrast == .increased ? .white : AquaDark.textPrimary)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    case .code(let language, let code):
                        CodeBlock(language: language, code: code)
                    }
                }
                if !message.results.isEmpty { SearchResultsView(items: message.results, answer: message.text) }
            }
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Code, formulas and commands: monospaced on a dark panel, with the language and a
/// Copy button; long lines scroll sideways instead of wrapping.
private struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false
    @Environment(\.chatRenderCopied) private var renderCopied

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AquaDark.textTertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    // A small graphite gel pill; "Copied" ticks in Aqua green.
                    let done = copied || renderCopied
                    HStack(spacing: 4) {
                        Image(systemName: done ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(done ? AquaDark.aquaGreen : .white.opacity(0.85))
                        Text(done ? "Copied" : "Copy").foregroundStyle(.white.opacity(0.95))
                    }
                    .shadow(color: .black.opacity(0.35), radius: 0, y: -0.5)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(CopyGel())
                }
                .buttonStyle(AquaPressStyle())
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 4)

            // Long lines wrap: in a sideways scroll view a line wider than the card was shifted
            // left and cut off at both ends. Copy still gives the exact code.
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(white: 0.9))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        // A darker, still see-through inset well, so code stays readable over anything.
        .background(AquaWell(shape: RoundedRectangle(cornerRadius: 10, style: .continuous), darkness: 0.5, bordered: true))
        .environment(\.colorScheme, .dark)
    }
}

/// The panel behind the chat: the dark heads-up blur (kept: the panel stays see-through),
/// with the dark Aqua tint, pinstripes, border and highlight on top (`AquaBody`).
private struct SiriPanel: View {
    @Environment(\.chatBackdrop) private var backdrop

    var body: some View {
        ZStack {
            if let backdrop { RenderedBlur(backdrop: backdrop) } else { HUDBlur() }
            AquaBody()
        }
        .allowsHitTesting(false)
    }
}

/// For renders: the picture behind the card, blurred and darkened about as the heads-up
/// material does, so before/after renders show the same see-through.
struct RenderedBlur: View {
    let backdrop: ChatBackdrop

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: backdrop.image)
                .resizable()
                .frame(width: backdrop.size.width, height: backdrop.size.height)
                .offset(x: -backdrop.origin.x, y: -backdrop.origin.y)
                .blur(radius: 24, opaque: true)
            Color(white: 0.12).opacity(0.45)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

/// `NSVisualEffectView` with the heads-up window material, blurring what's behind the window.
private struct HUDBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// An AppKit view that moves its window when dragged. Sits behind the card's content,
/// so it receives clicks on empty areas only.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// The header's close button: a small round Aqua red gel, like the old window close
/// button; its ✕ shows on hover.
private struct CloseGel: View {
    let hovering: Bool
    @Environment(\.aquaPressed) private var pressed

    var body: some View {
        ZStack {
            AquaGel(palette: .red, shape: Circle(), pressed: pressed)
            Image(systemName: "xmark")
                .font(.system(size: 7.5, weight: .heavy))
                .foregroundStyle(AquaDark.hex(0x5A0B07).opacity(0.85))
                .opacity(hovering ? 1 : 0)
        }
        .frame(width: 14, height: 14)
        .frame(width: 20, height: 20)  // the same hit area as before
        .contentShape(Circle())
    }
}

/// The send button: a round Aqua blue gel, or graphite (no glow) when it can't send.
private struct SendGel: View {
    let palette: AquaPalette
    @Environment(\.aquaPressed) private var pressed

    var body: some View {
        ZStack {
            AquaGel(palette: palette, shape: Circle(), pressed: pressed)
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(palette.glow == nil ? 0.6 : 0.95))
                .shadow(color: .black.opacity(0.3), radius: 0, y: -0.5)
        }
        .frame(width: 22, height: 22)
    }
}

/// The code block's Copy pill: a small graphite gel lozenge.
private struct CopyGel: View {
    @Environment(\.aquaPressed) private var pressed

    var body: some View {
        AquaGel(palette: .graphite, shape: Capsule(), pressed: pressed)
    }
}
