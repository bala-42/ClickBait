import AppKit
import ClickBaitCore
import SwiftUI

/// The chat bubble: the answer and any follow-ups, with a field to keep asking.
/// Same Liquid Glass card style as the companion.
struct ChatView: View {
    @Bindable var model: ChatModel

    static let width: CGFloat = 360
    private static let maxTranscriptHeight: CGFloat = 340
    @State private var transcriptHeight: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            Divider().opacity(0.5)
            inputRow
        }
        .frame(width: Self.width)
        // Empty parts of the card drag the window (SwiftUI content would otherwise
        // swallow the mouse-down before the window could move).
        .background(WindowDragArea())
        .modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.cardSize = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.16), in: Circle())
            Text("ClickBait")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
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
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    if model.isBusy, model.messages.last?.role != .assistant {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .id("busy")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
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
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask a follow-up…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($fieldFocused)
                .onSubmit { model.send() }
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(MessageFormat.segments(message.text).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let prose):
                        Text(Self.markdown(prose))
                            .font(.system(size: 13))
                            .lineSpacing(1.5)
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

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(white: 0.9))
                    .lineSpacing(3)
                    .fixedSize()
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .scrollIndicators(.automatic)
        }
        .background(Self.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }
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
