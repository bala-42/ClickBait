import Foundation

/// The four brains ClickBait offers (user's ask, 2026-11-01, after Taby's): named by how much
/// they think, smallest first, the Ollama model behind each shown under an (i). All read the
/// screen. Download sizes are Ollama's (measured 2026-11-01); memory is what it holds while
/// answering, roughly. Standard is the model ClickBait already used (gemma4:e4b, MLX build).
///
/// Builds (measured 2026-11-01, ClickBait's 49 text cases): the MLX build of E4B answered in
/// 0.2 s median against 0.8–0.9 s for the 4-bit GGUF builds, at 46/49 against 48/49 (q4_K_M)
/// and 45/49 (QAT). So the brains for Macs with memory to spare use MLX (fast); Light, for
/// 8 GB Macs, uses the small 4-bit build, where memory matters more than speed.
public enum Brain: String, CaseIterable, Sendable, Identifiable {
    case light, standard, big, galaxy

    public var id: String { rawValue }

    public var name: String { "\(rawValue) brain" }

    /// The Ollama model to pull and run.
    public var model: String {
        switch self {
        case .light: "gemma4:e2b"
        case .standard: "gemma4:e4b-mlx"
        case .big: "qwen3.5:9b"
        case .galaxy: "gemma4:12b-mlx"
        }
    }

    /// Other names an installed copy may have (Standard was pulled as `gemma4:e4b` before).
    public var aliases: [String] {
        switch self {
        case .standard: ["gemma4:e4b"]
        default: []
        }
    }

    /// What the (i) says.
    public var modelLabel: String {
        switch self {
        case .light: "Gemma 4 E2B (Google), 4-bit"
        case .standard: "Gemma 4 E4B (Google), MLX"
        case .big: "Qwen 3.5 9B (Alibaba)"
        case .galaxy: "Gemma 4 12B (Google), MLX"
        }
    }

    public var blurb: String {
        switch self {
        case .light: "quickest to fit. good for everyday questions."
        case .standard: "sees your screen well, answers in a few seconds."
        case .big: "thinks things through. slower."
        case .galaxy: "the most capable. for macs with 32 GB or more."
        }
    }

    /// Download size in GB, as Ollama lists it.
    public var downloadGB: Double {
        switch self {
        case .light: 4.6
        case .standard: 9.5
        case .big: 6.6
        case .galaxy: 7.7
        }
    }

    /// Memory it holds while answering, roughly, in GB.
    public var memoryGB: Double {
        switch self {
        case .light: 6
        case .standard: 10
        case .big: 9
        case .galaxy: 11
        }
    }

    /// The smallest Mac (total memory, GB) it runs comfortably on.
    public var minimumMacGB: Double {
        switch self {
        case .light: 8
        case .standard, .big: 16
        case .galaxy: 32
        }
    }

    /// The largest brain that fits comfortably, never above Standard: bigger is a choice made
    /// on purpose. (Taby's field numbers: on 8 GB Macs most Standard installs failed and
    /// answers took a median 41 s against 6.5 s for Light.)
    public static func recommended(macMemoryGB: Double) -> Brain {
        macMemoryGB >= Brain.standard.minimumMacGB ? .standard : .light
    }

    /// The brain an Ollama model name belongs to, if any ("gemma4:e4b" → Standard).
    public static func matching(model: String) -> Brain? {
        let name = model.trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { $0.model == name || $0.aliases.contains(name) }
    }

    /// Is a brain installed, given Ollama's model names?
    public func isInstalled(in installed: [String]) -> Bool {
        let names = Set(installed.map { $0.lowercased() })
        return ([model] + aliases).contains { names.contains($0) }
    }

    /// How it fits this Mac, in a few words for its card; nil when it fits fine.
    public func fitNote(macMemoryGB: Double) -> String? {
        if macMemoryGB < minimumMacGB {
            return minimumMacGB > macMemoryGB * 1.5
                ? "needs \(Int(minimumMacGB)) GB · too big for this mac"
                : "this mac has \(Int(macMemoryGB)) GB, it would be slow"
        }
        return nil
    }
}
