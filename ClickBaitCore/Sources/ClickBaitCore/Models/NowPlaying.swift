import Foundation

/// Which source the notch's player shows (user's rule, 2026-10-23: "prioritise whatever is
/// PLAYING and where it's being played from"): Apple Music or Spotify, or a YouTube video in
/// a browser (playing when the browser is sending sound out, `AudioActivity`).
public enum NowPlaying {
    public enum Source: Equatable, Sendable { case player, youtube, none }

    /// `player`, `youtube`: nil when there's no track or video, else whether it's playing.
    /// `showingYouTube`: the video is what's shown now.
    public static func pick(player: Bool?, youtube: Bool?, showingYouTube: Bool) -> Source {
        if player == true { return .player }
        if youtube == true { return .youtube }
        // Nothing playing: what's shown stays while it's there, else the paused track, else the video.
        if showingYouTube, youtube != nil { return .youtube }
        if player != nil { return .player }
        if youtube != nil { return .youtube }
        return .none
    }
}
