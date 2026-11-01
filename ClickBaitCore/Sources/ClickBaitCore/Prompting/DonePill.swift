import Foundation

/// What the cursor says when a docked job finishes (user's rule, 2026-10-23: not the answer
/// itself, a short note that the work is done, fitting the task it came from). Random among a
/// few, never the same twice running; lowercase like the companion's other pills.
public enum DonePill {
    public enum Task: Equatable, Sendable {
        case snip, walkthrough, files, code, why, how, answer
    }

    static let lines: [Task: [String]] = [
        .snip: ["your snip's figured out ✓", "worked out what you circled", "snip explained, in the dock ✓"],
        .walkthrough: ["steps ready, say show me!", "your walkthrough's planned ✓", "ready to walk you through it"],
        .files: ["your files are ready ✓", "file job done, in the dock", "all converted, in the dock ✓"],
        .code: ["your code's ready ✓", "code written, in the dock", "fresh code, in the dock ✓"],
        .why: ["got the why for you ✓", "the why is in the dock", "figured out why ✓"],
        .how: ["here's how, in the dock ✓", "worked out the how", "the how-to is ready ✓"],
        .answer: ["your answer's ready ✓", "done thinking, it's in the dock", "answered, in the dock ✓"],
    ]

    /// The kind of task a job was, from what it was and what it asked and got.
    public static func task(kind: BackgroundJob.Kind, question: String, answer: String) -> Task {
        switch kind {
        case .snip: return .snip
        case .walkthrough: return .walkthrough
        case .files: return .files
        case .answer:
            if answer.contains("```") { return .code }
            let words = question.lowercased().split { !$0.isLetter && $0 != "'" }
            if let first = words.first, first == "why" || first == "why's" { return .why }
            if words.prefix(3).contains("how") { return .how }
            return .answer
        }
    }

    public static func line<R: RandomNumberGenerator>(for task: Task, after previous: String?, using random: inout R) -> String {
        let choices = lines[task] ?? lines[.answer]!
        return choices.filter { $0 != previous }.randomElement(using: &random) ?? choices[0]
    }

    public static func line(for task: Task, after previous: String?) -> String {
        var random = SystemRandomNumberGenerator()
        return line(for: task, after: previous, using: &random)
    }
}
