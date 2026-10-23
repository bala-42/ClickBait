import Testing
@testable import ClickBaitCore

struct NowPlayingTests {
    @Test func playingWinsWhereverItIs() {
        #expect(NowPlaying.pick(player: false, youtube: true, showingYouTube: false) == .youtube)
        #expect(NowPlaying.pick(player: true, youtube: false, showingYouTube: true) == .player)
        #expect(NowPlaying.pick(player: nil, youtube: true, showingYouTube: false) == .youtube)
    }

    @Test func nothingPlayingKeepsWhatsShown() {
        #expect(NowPlaying.pick(player: false, youtube: false, showingYouTube: true) == .youtube)
        #expect(NowPlaying.pick(player: false, youtube: false, showingYouTube: false) == .player)
        #expect(NowPlaying.pick(player: false, youtube: nil, showingYouTube: true) == .player)  // the tab closed
        #expect(NowPlaying.pick(player: nil, youtube: false, showingYouTube: false) == .youtube)
        #expect(NowPlaying.pick(player: nil, youtube: nil, showingYouTube: true) == .none)
    }
}
