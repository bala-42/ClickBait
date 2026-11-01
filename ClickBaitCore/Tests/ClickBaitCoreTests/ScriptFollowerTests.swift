import Testing
@testable import ClickBaitCore

struct ScriptFollowerTests {
    static let script = """
        Hello
        Hi, I'm Bala. This is ClickBait, a little triangle that lives by your cursor.
        Ask about anything on your screen. It all runs on this Mac.

        The notch
        Up here, the notch holds your music and a shelf for files.
        """

    @Test func followsAlongAsWordsAreHeard() {
        var follower = ScriptFollower(readable: Self.script)
        #expect(follower.hear("hi I'm bala")?.line == 1)
        #expect(follower.hear("hi I'm bala this is clickbait a little triangle")?.line == 1)
        let place = follower.hear("triangle that lives by your cursor")
        #expect(place?.line == 1)
        #expect((place?.fraction ?? 0) > 0.9)
        #expect(follower.hear("ask about anything on your screen")?.line == 2)
    }

    @Test func forgivesMishearingsAdLibsAndSkips() {
        var follower = ScriptFollower(readable: Self.script)
        follower.hear("hi I'm bala this is clickbait")
        #expect(follower.hear("a little triangel that lives")?.line == 1)       // misheard
        #expect(follower.hear("lives um by your cursor")?.line == 1)            // ad-libbed "um"
        #expect(follower.hear("ask about on your screen")?.line == 2)           // skipped "anything"
    }

    @Test func staysPutOffScriptAndWhenSilent() {
        var follower = ScriptFollower(readable: Self.script)
        follower.hear("hi I'm bala this is clickbait")
        let before = follower.place
        #expect(follower.hear("sorry let me get some water") == nil)
        #expect(follower.hear("") == nil)
        #expect(follower.place == before)
    }

    @Test func aCommonWordAloneDoesntJumpAhead() {
        var follower = ScriptFollower(readable: Self.script)
        follower.hear("hi I'm bala")
        // "the" is all over the script; one word far ahead isn't a match.
        #expect(follower.hear("the") == nil)
    }

    @Test func resumesFromAJump() {
        var follower = ScriptFollower(readable: Self.script)
        follower.resume(atLine: 5)
        #expect(follower.hear("up here the notch holds")?.line == 5)
    }

    @Test func twoCommonWordsDontLeapFarAhead() {
        var follower = ScriptFollower(readable: Self.script + "\nAnd that is all from me, thank you so much.")
        follower.hear("hi I'm bala this is clickbait")
        // "thank you" is far ahead; two words alone don't take reading there.
        #expect(follower.hear("thank you") == nil)
        #expect(follower.place?.line == 1)
    }
}
