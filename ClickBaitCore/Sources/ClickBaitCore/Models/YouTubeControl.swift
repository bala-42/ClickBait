import Foundation

/// Controlling a YouTube video in its own browser tab, once the user has turned on the
/// browser's "Allow JavaScript from Apple Events" (Chrome: View → Developer; Safari: Develop
/// menu). Pure: the scripts and the parsing; the app runs them. Without the switch the
/// browser refuses (`isTurnedOff`) and the notch falls back to the media keys.
public enum YouTubeControl {
    static let separator = "\u{1F}"

    /// "playing|paused", position, duration, channel — joined by U+001F; "" without a video.
    public static let readState = """
        (()=>{const v=document.querySelector('video.html5-main-video')||document.querySelector('video');if(!v)return '';\
        const c=document.querySelector('#owner #channel-name a, ytd-video-owner-renderer #channel-name a');\
        return [v.paused?'paused':'playing',v.currentTime.toFixed(1),(isFinite(v.duration)?v.duration:0).toFixed(1),\
        (c&&c.textContent||'').trim()].join('\\u001f')})()
        """
    /// Pauses (never starts) the video.
    public static let pause = "(()=>{const v=document.querySelector('video.html5-main-video')||document.querySelector('video');if(!v)return '';v.pause();return 'ok'})()"
    /// YouTube's own play button (it keeps the player's state right, where a bare video.play()
    /// can be refused or hit a preview video); the main video only without one.
    public static let playPause = "(()=>{const b=document.querySelector('#movie_player .ytp-play-button');if(b){b.click();return 'ok'}const v=document.querySelector('video.html5-main-video')||document.querySelector('video');if(!v)return '';if(v.paused){v.play()}else{v.pause()}return 'ok'})()"
    /// The player's next button (a playlist or autoplay's next video).
    public static let next = "(()=>{const b=document.querySelector('.ytp-next-button');if(!b)return '';b.click();return 'ok'})()"
    /// Back to the start; already near it, the previous video.
    public static let previous = """
        (()=>{const v=document.querySelector('video.html5-main-video')||document.querySelector('video');if(!v)return '';if(v.currentTime>3){v.currentTime=0;return 'ok'}\
        const b=document.querySelector('.ytp-prev-button');if(b&&b.offsetParent){b.click()}else{history.back()}return 'ok'})()
        """

    public static func seek(to seconds: Double) -> String {
        "(()=>{const v=document.querySelector('video.html5-main-video')||document.querySelector('video');if(!v)return '';v.currentTime=\(String(format: "%.1f", max(0, seconds)));return 'ok'})()"
    }

    /// The AppleScript running `javascript` in exactly that tab; "gone" if it closed.
    public static func appleScript(_ javascript: String, in tab: BrowserTab) -> String {
        let js = javascript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        switch tab.browser {
        case .chrome:
            return """
                tell application id "\(tab.browser.rawValue)"
                    repeat with w in windows
                        if id of w is \(tab.windowID) then
                            repeat with t in tabs of w
                                if id of t is \(tab.tab) then return (execute t javascript "\(js)")
                            end repeat
                        end if
                    end repeat
                    return "gone"
                end tell
                """
        case .safari:
            return """
                tell application id "\(tab.browser.rawValue)"
                    try
                        return (do JavaScript "\(js)" in tab \(tab.tab) of window id \(tab.windowID))
                    on error number -1728
                        return "gone"
                    end try
                end tell
                """
        }
    }

    /// Asks Chrome to run a harmless `1` in its front tab: fails with `isTurnedOff` while
    /// the switch is off.
    public static let chromeProbe = #"tell application id "com.google.Chrome" to execute active tab of front window javascript "1""#

    public struct State: Equatable, Sendable {
        public let playing: Bool
        public let position: Double
        public let duration: Double
        public let channel: String
    }

    public static func parse(_ output: String) -> State? {
        let fields = output.components(separatedBy: separator)
        guard fields.count == 4, ["playing", "paused"].contains(fields[0]),
              let position = Double(fields[1]), let duration = Double(fields[2]) else { return nil }
        return State(playing: fields[0] == "playing", position: position, duration: duration,
                     channel: fields[3].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The browser said its JavaScript-from-Apple-Events switch is off.
    public static func isTurnedOff(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("javascript") && (text.contains("turned off") || text.contains("apple events") || text.contains("not allowed"))
    }
}
