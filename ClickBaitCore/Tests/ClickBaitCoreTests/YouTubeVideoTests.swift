import Testing
@testable import ClickBaitCore

struct YouTubeVideoTests {
    @Test func readsWatchShortsAndShortLinks() {
        #expect(YouTubeVideo(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=4", tabTitle: "x")?.id == "dQw4w9WgXcQ")
        #expect(YouTubeVideo(url: "https://youtube.com/shorts/abcdefghijk", tabTitle: "x")?.id == "abcdefghijk")
        #expect(YouTubeVideo(url: "https://youtu.be/A_b-123456Z?si=1", tabTitle: "x")?.id == "A_b-123456Z")
        #expect(YouTubeVideo(url: "https://music.youtube.com/watch?v=dQw4w9WgXcQ", tabTitle: "x")?.id == "dQw4w9WgXcQ")
    }

    @Test func ignoresPagesThatArentOneVideo() {
        for url in ["https://www.youtube.com/", "https://www.youtube.com/results?search_query=a",
                    "https://www.youtube.com/watch?v=short", "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
                    "https://www.youtube.com/watch?v=dQw4w9WgX%22Q", "file:///watch?v=dQw4w9WgXcQ"] {
            #expect(YouTubeVideo(url: url, tabTitle: "x") == nil, "\(url)")
        }
    }

    @Test func cleansTheTabTitle() {
        #expect(YouTubeVideo.cleaned("(12) Never Gonna Give You Up - YouTube") == "Never Gonna Give You Up")
        #expect(YouTubeVideo.cleaned("Song - YouTube Music") == "Song")
        #expect(YouTubeVideo.cleaned("(Live) Song - YouTube") == "(Live) Song")
        #expect(YouTubeVideo.cleaned(" - YouTube") == "YouTube")
    }

    @Test func thumbnailIsTheWideOne() {
        #expect(YouTubeVideo(url: "https://youtu.be/dQw4w9WgXcQ", tabTitle: "")?.thumbnail.absoluteString
                == "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
    }
}
