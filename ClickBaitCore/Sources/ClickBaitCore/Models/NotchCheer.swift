import Foundation

/// The open notch's header line (user's choice, 2026-10-23, in place of the home, ask and
/// shelf tabs): a small cheer, joke or nudge, all lowercase, with a kaomoji, 30 characters at most. A new one each
/// time the notch opens or the line is clicked, never the one just shown.
public enum NotchCheer {
    public static let lines = [
        "you're doing great (๑˃ᴗ˂)ﻭ",
        "one step at a time ( ˶ˆᗜˆ˵ )",
        "drink some water (っ˘ڡ˘ς)",
        "the bug fears you ᕦ(ò_ó)ᕤ",
        "future you says thanks (◕‿◕)",
        "works on my machine ¯\\_(ツ)_/¯",
        "progress > perfection (ᵔᴥᵔ)",
        "stretch real quick ヽ(•‿•)ノ",
        "light attracts bugs (ﾉ◕ヮ◕)ﾉ",
        "you've got this (•ᴗ•)و",
        "tiny wins count (˶ᵔ ᵕ ᵔ˶)",
        "breathe, then dive in (￣▽￣)ノ",
        "i believe in you (｡•ᴗ-)✧",
        "done beats perfect ✌(-‿-)✌",
        "a nap is a plan (－_－) zzz",
        "your tabs judge you (¬‿¬)",
        "no place like 127.0.0.1 (◕ᴗ◕)",
        "be kind to yourself (｡♥‿♥｡)",
        "fix one, two appear (╯°□°)╯",
        "rest is work too (ᴗ˳ᴗ)",
        "look at you go (≧▽≦)",
        "coffee's on your side ( ˘▽˘)っ♨",
        "one commit to glory (•ᴗ•)",
        "closer than you think (ง •_•)ง",
        "this bean is proud (◍•ᴗ•◍)",
    ]

    /// A line other than `previous`.
    public static func next<R: RandomNumberGenerator>(after previous: String?, using random: inout R) -> String {
        lines.filter { $0 != previous }.randomElement(using: &random) ?? lines[0]
    }

    public static func next(after previous: String?) -> String {
        var random = SystemRandomNumberGenerator()
        return next(after: previous, using: &random)
    }
}
