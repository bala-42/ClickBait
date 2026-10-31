import Foundation

/// Getting the model onto a friend's Mac from ClickBait itself: Ollama's own download
/// (`/api/pull`), with progress, instead of `ollama pull` in Terminal; and one short test
/// answer at the end of setup, proving the whole path works.
public enum OllamaSetup {
    /// One line of `/api/pull`'s stream: what it's doing and how far (0…1) when known.
    public struct Progress: Equatable, Sendable {
        public let status: String
        public let fraction: Double?
        public var isDone: Bool { status == "success" }
    }

    public enum PullError: Error, Equatable {
        case notRunning
        case failed(String)
    }

    /// `{"status":"pulling 4c27e0f5b5ad","total":6600000000,"completed":330000000}` → 5%.
    public static func parse(line: String) -> Progress? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? String { return Progress(status: "error: " + error, fraction: nil) }
        guard let status = json["status"] as? String else { return nil }
        let total = (json["total"] as? NSNumber)?.doubleValue ?? 0
        let completed = (json["completed"] as? NSNumber)?.doubleValue ?? 0
        return Progress(status: status, fraction: total > 0 ? min(completed / total, 1) : nil)
    }

    /// Downloads `model`, reporting each step. Resumable: Ollama keeps what it already has.
    public static func pull(_ model: String, onProgress: @Sendable (Progress) -> Void) async throws {
        var request = URLRequest(url: OllamaProvider.baseURL.appending(path: "api/pull"), timeoutInterval: 60 * 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let bytes: URLSession.AsyncBytes
        do { (bytes, _) = try await URLSession.shared.bytes(for: request) } catch { throw PullError.notRunning }
        for try await line in bytes.lines {
            guard let progress = parse(line: line) else { continue }
            if progress.status.hasPrefix("error: ") { throw PullError.failed(String(progress.status.dropFirst(7))) }
            onProgress(progress)
            if progress.isDone { return }
        }
    }

    /// The models Ollama has, or nil when it isn't running (for the brain cards).
    public static func installedModels() async -> [String]? {
        let request = URLRequest(url: OllamaProvider.baseURL.appending(path: "api/tags"), timeoutInterval: 3)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// A one-line hello from the model, or nil: setup's last check. Same context size as
    /// real requests, so the model stays loaded for the first question.
    public static func hello(_ model: String) async -> String? {
        var request = URLRequest(url: OllamaProvider.baseURL.appending(path: "api/generate"), timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "keep_alive": OllamaProvider.keepAlive, "think": false,
            "options": ["num_ctx": OllamaProvider.contextTokens, "num_predict": 40],
            "prompt": "You are ClickBait, a friendly helper that lives on the user's Mac. Say hello in one short sentence, all lowercase, no emoji.",
        ])
        guard let request = Optional(request), let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = (json["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// The setup window's steps, one at a time (Clicky-style; user's ask, 2026-10-25).
/// Setup in Taby's order (user's ask, 2026-11-01): hello, the brain first (it downloads while
/// the rest goes on), the three permissions, the speech model, the notch, saying hello, then
/// the first question (`ready`).
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, model, microphone, accessibility, screenRecording, speech, notch, hello, ready

    /// Where to open: the welcome the first time, then the first step not done yet, so
    /// reopening after Screen Recording carries on instead of starting over.
    public static func start(welcomed: Bool, done: Set<OnboardingStep>) -> OnboardingStep {
        guard welcomed else { return .welcome }
        return allCases.first { $0 != .welcome && $0 != .ready && !done.contains($0) } ?? .ready
    }

    public var next: OnboardingStep { OnboardingStep(rawValue: rawValue + 1) ?? .ready }
    public var previous: OnboardingStep { OnboardingStep(rawValue: rawValue - 1) ?? .welcome }
}
