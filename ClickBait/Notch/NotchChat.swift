import ClickBaitCore
import Foundation

/// The notch's own Ask (user's call, 2026-11-02: "the ask function in the notch should stay
/// separately from the chatbot overlay asks"): one conversation that stays, like the shelf's
/// files, until cleared or ClickBait quits. It doesn't look at the screen unless asked (the eye
/// button: a screenshot goes with the next message), and remembers its own turns, so follow-ups
/// work. The overlay chats (⌃⌥, ⌥⌘) never see it, nor it them; the model takes them in turn.
@MainActor
final class NotchChat {
    let model = ChatModel()
    /// The brain's name (set by the app delegate).
    var brain: () -> String = { "" }
    /// A JPEG of the screen under the pointer, or nil (no permission, failed).
    var look: () async -> Data? = { nil }

    private struct Turn {
        let role: String
        let text: String
        let image: Data?
    }
    private var turns: [Turn] = []
    private var task: Task<Void, Never>?
    /// Turns sent to the model: the latest this many (the context stays small and quick).
    private static let memory = 20

    init() {
        model.offersLook = true
        model.onSend = { [weak self] text in self?.send(text) }
    }

    func send(_ text: String) {
        guard !model.isBusy else { return }
        model.addUser(text)
        model.isBusy = true
        let looking = model.looksAtScreen
        model.looksAtScreen = false
        task = Task { await answer(text, looking: looking) }
    }

    /// Everything forgotten: the 🗑 in its header.
    func clear() {
        task?.cancel()
        task = nil
        turns = []
        model.messages = []
        model.isBusy = false
        model.looksAtScreen = false
    }

    private func answer(_ text: String, looking: Bool) async {
        let image = looking ? await look() : nil
        if looking, image == nil { model.addError("I couldn't see the screen (Screen Recording may be off), so this answer is without it.") }
        turns.append(Turn(role: "user", text: text, image: image))
        var reply = ""
        do {
            for try await chunk in Self.stream(Array(turns.suffix(Self.memory)), brain: brain()) {
                guard !Task.isCancelled else { return }
                reply += chunk
                model.setAssistant(reply)
            }
            if reply.isEmpty { model.addError("No answer came back. Is Ollama running?") }
            turns.append(Turn(role: "assistant", text: reply, image: nil))
        } catch {
            guard !Task.isCancelled else { return }
            turns.removeLast()  // unanswered: not part of what was said
            model.addError("That didn't work: \(error.localizedDescription)")
        }
        model.isBusy = false
    }

    nonisolated private static let system = """
        You are ClickBait, a friendly assistant that lives in the notch of the user's Mac and \
        runs entirely on it. Answer clearly and briefly in plain language; use Markdown only for \
        lists and code. If an image comes with a message, it is a screenshot of the user's screen \
        that they asked you to look at.
        """

    /// Ollama's chat, streamed: the system line, then the turns (a screenshot only on the turn
    /// it was taken for).
    nonisolated private static func stream(_ turns: [Turn], brain: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    var messages: [[String: Any]] = [["role": "system", "content": system]]
                    for turn in turns {
                        var message: [String: Any] = ["role": turn.role, "content": turn.text]
                        if let image = turn.image { message["images"] = [image.base64EncodedString()] }
                        messages.append(message)
                    }
                    var request = URLRequest(url: OllamaProvider.baseURL.appending(path: "api/chat"), timeoutInterval: 120)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    // The same context size as ClickBait's other asks, so Ollama doesn't reload the model.
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": brain, "messages": messages, "stream": true, "think": false,
                        "keep_alive": OllamaProvider.keepAlive, "options": ["num_ctx": OllamaProvider.contextTokens],
                    ] as [String: Any])
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw LLMError.invalidResponse("Ollama answered \(http.statusCode)")
                    }
                    for try await line in bytes.lines {
                        guard let (text, done) = try OllamaStreamDecoder.decode(line: line) else { continue }
                        if !text.isEmpty { continuation.yield(text) }
                        if done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}
