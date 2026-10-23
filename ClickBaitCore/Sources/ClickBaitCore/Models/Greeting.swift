import Foundation

/// A hello by the cursor when the user comes back (user's request, 2026-10-20; the idea of
/// HeyClicky's greeting pill, with ClickBait's own lines and colour). On the first wake or
/// unlock of the day, or after a long time away: one short line with a kaomoji, typed out in
/// the companion's pill, then gone. Written lines, no model call: instant, free, offline.
///
///     Greeting.shouldGreet(now: now, awaySince: lastNight, lastGreeted: yesterday)  // true
///     Greeting.line(at: now, recent: [])  // (index: 3, text: "morning (•‿•)")
public enum Greeting {
    public enum Period: String, CaseIterable, Sendable {
        case morning, afternoon, evening, lateNight

        /// 5–11 morning, 12–16 afternoon, 17–21 evening, 22–4 late night.
        public init(hour: Int) {
            switch hour {
            case 5..<12: self = .morning
            case 12..<17: self = .afternoon
            case 17..<22: self = .evening
            default: self = .lateNight
            }
        }
    }

    /// Away this long counts as "a good while", any time of day.
    public static let longAway: TimeInterval = 4 * 3600
    /// The day's first greeting still needs a real break: not a 2-minute lock just after midnight.
    public static let minimumAway: TimeInterval = 30 * 60
    /// Lines not repeated until this many others have been shown.
    public static let recentMemory = 8

    /// Greet on coming back? The first time today (after at least `minimumAway`, or at launch
    /// when `awaySince` is unknown), or after `longAway` whatever the day.
    public static func shouldGreet(now: Date, awaySince: Date?, lastGreeted: Date?, calendar: Calendar = .current) -> Bool {
        let away = awaySince.map { now.timeIntervalSince($0) }
        if let away, away >= longAway { return true }
        let greetedToday = lastGreeted.map { calendar.isDate($0, inSameDayAs: now) } ?? false
        guard !greetedToday else { return false }
        return away.map { $0 >= minimumAway } ?? true
    }

    public static let lines: [Period: [String]] = [
        .morning: [
            "good morning (｡•ᴗ-)✧",
            "morning! ready when you are (•ᴗ•)و",
            "rise and shine ✧*｡٩(ˊᗜˋ*)و✧*｡",
            "morning (•‿•)",
            "coffee first, clicks later ( ˘▽˘)っ旦",
            "oh hi! new day, new tabs (ﾉ◕ヮ◕)ﾉ*:･ﾟ✧",
            "good morning, i missed you (っ˘ω˘ς)",
            "*yawns* oh, you're up! (。-ω-)zzz → (•ᴗ•)",
            "a fresh morning (˶ᵔ ᵕ ᵔ˶)",
            "morning! let's make it a good one ٩(◕‿◕)۶",
        ],
        .afternoon: [
            "oh hi, you're back (ﾉ◕ヮ◕)ﾉ*:･ﾟ✧",
            "welcome back (•‿•)ﾉ",
            "good afternoon ( ´ ▽ ` )ﾉ",
            "hey hey! (＾▽＾)",
            "back for more? let's go (ง •_•)ง",
            "hello again ヾ(＾∇＾)",
            "i kept your cursor warm (˘ω˘)",
            "afternoon! snack break done? (っ˘ڡ˘ς)",
            "there you are (≧◡≦)",
            "hi! what are we clicking today? (•ᴗ•)?",
        ],
        .evening: [
            "good evening ☾ (˘ᵕ˘)",
            "evening! (•‿•)ﾉ",
            "welcome back, night owl in training (◕‿◕)",
            "evening! cosy clicking time ( ˘ ³˘)♡",
            "oh hey, you're back (＾▽＾)",
            "the sun's off duty, i'm not (•ᴗ•)✧",
            "hello hello ヾ(•ω•`)o",
            "evening, let's wrap up (ᵔᴥᵔ)",
            "back again! i missed you (｡♡‿♡｡)",
            "evening vibes ✧ (˶˘ ³˘)",
        ],
        .lateNight: [
            "up late? me too (◡‿◡✿)",
            "hi, it's late! (｡•︿•｡)",
            "midnight clicking club ☾ (•‿•)",
            "shh, everyone's asleep (˘ω˘)",
            "late night! don't forget to rest ( ˘ ³˘)♡",
            "oh, a night owl (ʘ‿ʘ)",
            "still here, still clicking (•ᴗ•)و",
            "the quiet hours ✧ (ᴗ˳ᴗ)",
        ],
    ]

    /// A line for now, not one of `recent` (indices into the period's lines) unless all are;
    /// `random` picks among the rest (a test passes a fixed one).
    public static func line(at now: Date, recent: [Int], calendar: Calendar = .current,
                            random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> (index: Int, text: String) {
        let period = Period(hour: calendar.component(.hour, from: now))
        let pool = lines[period] ?? []
        let fresh = pool.indices.filter { !recent.contains($0) }
        let choices = fresh.isEmpty ? Array(pool.indices) : fresh
        let index = choices[random(choices.count)]
        return (index, pool[index])
    }

    /// Typing speed (characters a second) and how long the whole line stays after it's typed:
    /// 1.5 s, a little more for longer lines, at most 2.5 s (user's call: 5 s was too long).
    public static let charactersPerSecond = 35.0
    public static func timing(for text: String) -> (typing: TimeInterval, hold: TimeInterval) {
        let count = Double(text.count)
        return (count / charactersPerSecond, min(max(0.6 + count * 0.03, 1.5), 2.5))
    }
}
