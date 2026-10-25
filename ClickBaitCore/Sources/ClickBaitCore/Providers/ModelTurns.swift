import Foundation
import os

/// Your question first (user's ask, 2026-10-25). Ollama answers one request at a time, so a
/// question asked while a dock task was writing waited for all of it (15 s instead of ~3 s,
/// busy-dock test). Now a foreground request counts itself in `ModelTurns`, and a background
/// one waits for its turn before it starts. One already writing runs to its end: Ollama
/// can't carry on a half-written Gemma answer (it closes the turn and Gemma starts afresh,
/// tried 2026-10-25), so pausing mid-answer garbled the code.
public final class ModelTurn: Sendable {
    private let background: OSAllocatedUnfairLock<Bool>

    public init(background: Bool = false) {
        self.background = OSAllocatedUnfairLock(initialState: background)
    }

    public var isBackground: Bool { background.withLock { $0 } }

    /// The answer moved to the dock: from now on it gives way.
    public func sendToBackground() { background.withLock { $0 = true } }
}

public enum ModelTurns {
    private static let foreground = OSAllocatedUnfairLock(initialState: 0)

    /// A foreground request is waiting for or getting an answer.
    public static var foregroundBusy: Bool { foreground.withLock { $0 > 0 } }

    static func enter() { foreground.withLock { $0 += 1 } }
    static func leave() { foreground.withLock { $0 = max($0 - 1, 0) } }

    /// Returns once no foreground request is running (checked every 100 ms).
    static func waitForTurn() async {
        while foregroundBusy, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
    }
}
