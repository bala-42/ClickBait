import AppKit
import ClickBaitCore
import SwiftUI

/// The chat, styled after the Siri overlay: a Liquid Glass card with no hard lines,
/// each question small and grey with its answer as the main text below, a soft
/// "Ask ClickBait…" capsule, and a spring in from the companion's corner.
struct ChatView: View {
    @Bindable var model: ChatModel

    static let width: CGFloat = 520
    static let corner: CGFloat = 26
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
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
        .background(WindowDragArea())
        // A dark, blurred, see-through panel (the macOS heads-up material), like Siri's.
        .background(SiriPanel())
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .environment(\.colorScheme, .dark)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.cardSize = $0 }
        // Grows out of the companion, and shrinks back into it.
        .scaleEffect(shown && !model.isClosing && !model.isTucked ? 1 : (reduceMotion ? 1 : 0.08), anchor: model.companionAnchor)
        .opacity(shown && !model.isClosing && !model.isTucked ? 1 : 0)
        .onAppear {
            // A beat later: the card has measured itself and knows where the companion is.
            DispatchQueue.main.async {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.8)) { shown = true }
            }
        }
        .animation(.easeIn(duration: 0.18), value: model.isClosing)
        // Tucks away quickly; comes back with the same spring it opened with.
        .animation(model.isTucked ? .easeIn(duration: 0.18)
                   : (reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.8)),
                   value: model.isTucked)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Same colour state as the companion: marigold while answering, blue
            // otherwise. Full size and resting angle, so it sits exactly on the companion.
            CompanionTriangle(tone: model.isBusy ? .processing : .idle, pulsing: false, spinning: model.isBusy)
                .frame(width: Self.headerRowHeight, height: Self.headerRowHeight)
                // Measured, not assumed: the chat places itself so this point is on the companion.
                .onGeometryChange(for: CGPoint.self) { proxy in
                    let frame = proxy.frame(in: .named(Self.cardSpace))
                    return CGPoint(x: frame.midX, y: frame.midY)
                } action: { model.logoOffset = $0 }
            Text("ClickBait")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(0.8)
            Spacer()
            Button {
                model.onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close chat")
        }
        .frame(height: Self.headerRowHeight)
        .padding(.horizontal, Self.headerLeading)
        .padding(.top, Self.headerTop)
        .padding(.bottom, 4)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.messages) { message in
                        MessageRow(message: message).id(message.id)
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
            .frame(height: min(transcriptHeight, Self.maxTranscriptHeight))
            .onChange(of: model.messages) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(model.messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private var inputRow: some View {
        // Centred: aligned at the bottom, the taller send button left a gap above the text.
        HStack(alignment: .center, spacing: 8) {
            TextField(model.messages.isEmpty ? "Ask ClickBait…" : "Ask a follow-up…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...4)
                .focused($fieldFocused)
                .onSubmit { model.send() }
                .onChange(of: model.focusRequest) { _, _ in fieldFocused = true }
                .onAppear { if model.focusRequest > 0 { fieldFocused = true } }
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        // A soft capsule like Siri's "Ask Siri…" field, no divider line above it.
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var canSend: Bool {
        !model.isBusy && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct MessageRow: View {
    let message: ChatModel.Message

    /// Inline markdown only (bold, italics, `code`, links); line breaks kept.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    var body: some View {
        switch message.role {
        case .user:
            // What was asked: small and grey, the answer below is the main text.
            Text(message.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
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
                            .font(.system(size: 15.5))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    case .code(let language, let code):
                        CodeBlock(language: language, code: code)
                    }
                }
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

    private static let background = Color(red: 0.09, green: 0.09, blue: 0.1)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
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
        .background(Self.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }
}

/// The panel behind the chat: the dark heads-up blur, darkened a touch, with two soft
/// glows — the companion's current colour top-right (orange while thinking), a cooler
/// one low in the middle.
private struct SiriPanel: View {
    var body: some View {
        ZStack {
            HUDBlur()
            Color.black.opacity(0.28)
        }
        .allowsHitTesting(false)
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
