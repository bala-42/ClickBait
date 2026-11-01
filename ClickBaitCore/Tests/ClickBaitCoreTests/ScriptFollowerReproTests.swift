import Testing
@testable import ClickBaitCore

/// The user's own script and what Whisper heard in their session (2026-11-01): nothing placed.
struct ScriptFollowerReproTests {
    static let script = """
# Introduction and Greeting
Hey, I'm Bala. This is ClickBait, and it's that little triangle that follows your mouse.

# Software Features Overview
Up in the notch, you've got your music, a spot for files, and now Studio. Studio has a mirror for quick looks, and it also has a teleprompter. You can ask it anything on your screen, and it all runs right on this Mac.

# Search Capabilities Demo
You can find a picture just by telling it what's in it. Or, you can find that note about the plumber.

# Conclusion and Farewell
Thanks for watching! Bye for now!
"""

    @Test func usersSession() {
        let readable = Script(text: Self.script).readable
        var follower = ScriptFollower(readable: readable)
        follower.resume(atLine: 4)
        var places: [Int] = []
        for heard in ["search demos and", "search demos and you can find", "you can find a", "you can find a picture",
                      "you can find a picture just by telling it", "find a picture just by telling it was in form"] {
            if let place = follower.hear(heard) { places.append(place.line) }
        }
        print("REPRO places:", places, "lines:", readable.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { "\($0.offset): \($0.element.prefix(30))" })
        #expect(!places.isEmpty)
    }
}
