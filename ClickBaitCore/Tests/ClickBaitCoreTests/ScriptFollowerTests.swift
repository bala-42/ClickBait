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

    @Test func placesAFractionalWordAndPromptsOnlyWhatWasRead() {
        var follower = ScriptFollower(readable: Self.script)
        #expect(follower.readSoFar() == "")
        follower.hear("hi I'm bala this is clickbait")
        #expect(follower.readSoFar().hasSuffix("this is clickbait"))
        #expect(!follower.readSoFar().contains("triangle"))
        // Line 1 has 14 words; halfway between words 5 and 6 of it.
        let place = follower.placement(ofWord: 1 + 5.5)
        #expect(place?.line == 1)
        #expect(abs((place?.fraction ?? 0) - 6.5 / 14) < 0.001)
    }

    @Test func findsTheReaderAfterALongSkip() {
        let long = "Hello\nHi I'm Bala.\n" + String(repeating: "This sentence is only padding to make a long paragraph here. ", count: 8)
            + "\nYou can find a picture just by telling it what's in it.\nBye for now."
        var follower = ScriptFollower(readable: long)
        follower.hear("hi I'm bala")
        // Skipped the padding (80 words): found again on four words in order.
        #expect(follower.hear("you can find a picture just by telling")?.line == 3)
        // Three words far away don't move it.
        var other = ScriptFollower(readable: long)
        other.hear("hi I'm bala")
        #expect(other.hear("bye for now") == nil)
    }
}
