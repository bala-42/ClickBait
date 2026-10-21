/// ClickBait's health as one line (the menu's dot line, the notch's status): the worst thing
/// wrong right now, worst first — Ollama off, the model missing, a permission switched off
/// (Screen Recording, Accessibility, Microphone, in that order), the model asleep — else
/// ready. Pure. Idea from Sentient OS's health banner.
///
///     HealthLadder.worst(model: .ready, permissionsOff: ["Screen Recording"])  // .permissionOff("Screen Recording")
public enum HealthLadder {
    public enum Item: Equatable, Sendable {
        case ollamaOff
        case modelMissing(String)
        /// A permission ClickBait was refused or had taken away, by its System Settings name.
        case permissionOff(String)
        /// Installed but not in memory: the first answer is slower. Not a problem.
        case modelAsleep
        case ready

        /// Needs the user to do something.
        public var isProblem: Bool {
            switch self {
            case .ollamaOff, .modelMissing, .permissionOff: true
            case .modelAsleep, .ready: false
            }
        }
    }

    /// `model` nil: not known yet. `permissionsOff` in the order to report them. Nil only while
    /// the model isn't known and nothing else is wrong.
    public static func worst(model: OllamaProvider.Health?, permissionsOff: [String]) -> Item? {
        switch model {
        case .unreachable: return .ollamaOff
        case .missing(let name): return .modelMissing(name)
        default: break
        }
        if let permission = permissionsOff.first { return .permissionOff(permission) }
        switch model {
        case .asleep: return .modelAsleep
        case .ready: return .ready
        default: return nil
        }
    }
}
