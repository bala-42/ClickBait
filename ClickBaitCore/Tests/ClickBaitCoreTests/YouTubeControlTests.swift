import Testing
@testable import ClickBaitCore

struct YouTubeControlTests {
    private let chromeTab = BrowserTab(browser: .chrome, windowID: 12, tab: 345, title: "x", url: "https://youtu.be/dQw4w9WgXcQ")

    @Test func scriptTargetsThatExactTabAndEscapes() {
        let script = YouTubeControl.appleScript(#"say("hi") \ "#, in: chromeTab)
        #expect(script.contains("if id of w is 12 then"))
        #expect(script.contains("if id of t is 345 then return (execute t javascript \"say(\\\"hi\\\") \\\\ \")"))
        let safari = YouTubeControl.appleScript("1", in: BrowserTab(browser: .safari, windowID: 7, tab: 2, title: "", url: ""))
        #expect(safari.contains("do JavaScript \"1\" in tab 2 of window id 7"))
    }

    @Test func readsTheVideosState() {
        let state = YouTubeControl.parse("playing\u{1F}12.5\u{1F}240.0\u{1F} Rick Astley ")
        #expect(state == YouTubeControl.State(playing: true, position: 12.5, duration: 240, channel: "Rick Astley"))
        #expect(YouTubeControl.parse("") == nil)
        #expect(YouTubeControl.parse("gone") == nil)
    }

    @Test func knowsWhenTheSwitchIsOff() {
        #expect(YouTubeControl.isTurnedOff("Executing JavaScript through AppleScript is turned off. To turn it on, from the menu bar, go to View > Developer > Allow JavaScript from Apple Events."))
        #expect(!YouTubeControl.isTurnedOff("Can't get window 1."))
    }

    @Test func seekNeverGoesNegative() {
        #expect(YouTubeControl.seek(to: -4).contains("v.currentTime=0.0"))
    }

    @Test func theStateSaysWhichVideoIsPlaying() {
        let state = YouTubeControl.parse("playing\u{1F}3.0\u{1F}200.0\u{1F}Chan\u{1F}https://www.youtube.com/watch?v=abc&index=41")
        #expect(state?.url == "https://www.youtube.com/watch?v=abc&index=41")
        #expect(YouTubeControl.readState.contains("location.href"))
    }
}
