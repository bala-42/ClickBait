/// The instructions and per-ask text every provider sends.
public enum Prompt {
    public static let system = """
        You are ClickBait, a helper that lives next to the user's cursor on their computer. \
        The user asked a question out loud while looking at their screen. You get a screenshot \
        of that screen plus what they said.

        Reply with ONLY one JSON object, no code fences and no other text:
        {"speech": "...", "pointers": [{"x": 0, "y": 0, "label": "..."}]}

        - "speech" comes first. It is read aloud: one or two short, friendly sentences, plain \
        words, no markdown, no lists. Say what to click and where it is.
        - "pointers" marks the exact things to click, in the order to click them (at most 3). \
        x and y are the CENTER of the element in screenshot pixels, origin at the top-left. \
        "label" is the element's visible text or a 1–3 word name for it.
        - Only point at things you can actually see in the screenshot. If the answer isn't \
        on screen, say what to do instead and use an empty "pointers" list.
        - If the question isn't about the screen, just answer it in "speech" with no pointers.
        - If the user highlighted text, explain it: a concise summary in 2–4 short sentences \
        that says what it means in plain words and why it matters here. Use the rest of the \
        screen (the app, document, surrounding text) for context, and briefly define any \
        jargon. Don't repeat the text back. Always use an empty "pointers" list.
        """

    /// Highlighted text beyond this is cut off; the screenshot still gives context.
    public static let maxSelectedCharacters = 6000

    /// The text that accompanies the screenshot.
    public static func userText(for request: AskRequest) -> String {
        var lines = ["The screenshot is \(request.screenshotWidth)×\(request.screenshotHeight) pixels."]
        let context = request.context
        if let app = context.appName, !app.isEmpty { lines.append("Frontmost app: \(app)") }
        if let title = context.windowTitle, !title.isEmpty { lines.append("Window title: \(title)") }
        if let focused = context.focusedElement, !focused.isEmpty { lines.append("Focused element: \(focused)") }
        lines.append("")
        if let selected = request.selectedText, !selected.isEmpty {
            lines.append("The user highlighted this text:")
            lines.append("<<<")
            lines.append(truncated(selected))
            lines.append(">>>")
            lines.append("")
            let question = request.question.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(question.isEmpty ? "Explain the highlighted text." : "The user said: \(question)")
        } else {
            lines.append("The user said: \(request.question)")
        }
        return lines.joined(separator: "\n")
    }

    static func truncated(_ text: String) -> String {
        guard text.count > maxSelectedCharacters else { return text }
        return String(text.prefix(maxSelectedCharacters)) + " […cut off]"
    }
}
