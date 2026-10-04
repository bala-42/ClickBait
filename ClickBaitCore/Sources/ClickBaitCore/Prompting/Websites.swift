import Foundation

/// Well-known websites by the names people say ("YouTube", "Gmail"): going to one is a
/// single typing step with an address from this list — never a model's guess, which can
/// be a look-alike domain (user's decision, 2026-10-04: well-known sites only).
public enum Websites {
    static let known: [(names: [String], address: String)] = [
        (["youtube"], "youtube.com"), (["gmail"], "mail.google.com"), (["google drive"], "drive.google.com"),
        (["google docs"], "docs.google.com"), (["google calendar"], "calendar.google.com"), (["google maps"], "maps.google.com"),
        (["google"], "google.com"), (["wikipedia"], "wikipedia.org"), (["facebook"], "facebook.com"),
        (["instagram"], "instagram.com"), (["twitter", "x com"], "x.com"), (["reddit"], "reddit.com"),
        (["linkedin"], "linkedin.com"), (["github"], "github.com"), (["netflix"], "netflix.com"),
        (["amazon"], "amazon.com"), (["chatgpt"], "chatgpt.com"), (["claude"], "claude.ai"),
        (["outlook", "hotmail"], "outlook.live.com"), (["whatsapp web"], "web.whatsapp.com"),
        (["spotify web", "spotify web player"], "open.spotify.com"), (["twitch"], "twitch.tv"),
        (["tiktok"], "tiktok.com"), (["pinterest"], "pinterest.com"), (["ebay"], "ebay.com"),
        (["stack overflow", "stackoverflow"], "stackoverflow.com"), (["bbc"], "bbc.co.uk"), (["icloud"], "icloud.com"),
    ]

    /// Words that make a request a visit ("open YouTube", "I want to watch YouTube",
    /// "take me to Gmail") rather than a question about the site ("what is Reddit?").
    static let visitWords: Set<String> = ["open", "go", "visit", "watch", "check", "browse", "take", "bring", "launch",
                                          "load", "want", "wanna", "like", "need", "read", "show", "get"]

    /// Nothing asked beyond getting there ("open YouTube", "I want to watch YouTube"):
    /// the walkthrough ends when the page opens. "Watch lofi on YouTube" has more to do.
    public static func isJustAVisit(_ request: String, site: String) -> Bool {
        let filler: Set<String> = ["i", "to", "the", "my", "me", "please", "can", "could", "you", "on", "in", "a", "up",
                                   "safari", "chrome", "browser", "website", "site", "page", "web", "app", "now", "com",
                                   "would", "id", "d", "go", "let", "lets", "s", "help", "into", "at", "for", "some"]
        let siteWords = Set(ImpliedPointer.normalized(site).split(separator: " ").map(String.init))
        return ImpliedPointer.normalized(request).split(separator: " ").map(String.init)
            .allSatisfy { filler.contains($0) || visitWords.contains($0) || siteWords.contains($0) }
    }

    /// A browser the request names ("on Chrome") as its app name, if one is listed in
    /// `installed`; nil means the default browser.
    public static func namedBrowser(in request: String, installed: [String]) -> String? {
        let spoken = " " + ImpliedPointer.normalized(request) + " "
        let browsers: [(said: String, app: String)] = [("safari", "Safari"), ("chrome", "Google Chrome"), ("firefox", "Firefox"),
                                                       ("arc", "Arc"), ("edge", "Microsoft Edge"), ("brave", "Brave Browser"),
                                                       ("opera", "Opera"), ("orion", "Orion")]
        return browsers.first { spoken.contains(" " + $0.said + " ") && installed.contains($0.app) }?.app
    }

    /// Said in a way that means the website, not an app of the same name: "claude.ai",
    /// "the Claude website", "Claude in Safari".
    static func meansWebsite(_ request: String) -> Bool {
        let raw = request.lowercased()
        let spoken = " " + ImpliedPointer.normalized(request) + " "
        if raw.range(of: #"\b[a-z0-9-]+\.(com|ai|org|net|tv|io|co|uk)\b"#, options: .regularExpression) != nil { return true }
        return [" website ", " site ", " web ", " browser ", " safari ", " chrome ", " firefox ", " arc ", " edge ", " online ",
                " web version ", " in the browser "].contains { spoken.contains($0) }
    }

    /// The site a request asks to go to, if it's a well-known one: (its name, address).
    /// `installedApps`: a site that's also an installed app ("Claude", "Spotify") means the
    /// app unless the request says the website — "open Claude" opened the browser at claude.ai.
    public static func visit(in request: String, installedApps: [String]) -> (name: String, address: String)? {
        guard let site = visit(in: request) else { return nil }
        let siteName = ImpliedPointer.normalized(site.name)
        let isApp = installedApps.contains { ImpliedPointer.normalized($0) == siteName }
        return isApp && !meansWebsite(request) ? nil : site
    }

    public static func visit(in request: String) -> (name: String, address: String)? {
        let words = ImpliedPointer.normalized(request).split(separator: " ").map(String.init)
        guard !words.isEmpty, !["what", "who", "why", "is", "does", "explain", "tell"].contains(words[0]),
              words.prefix(4).contains(where: visitWords.contains) else { return nil }
        let spoken = " " + words.joined(separator: " ") + " "
        // The longest name wins ("google drive" over "google").
        let matches = known.flatMap { site in site.names.map { ($0, site.address) } }
            .filter { spoken.contains(" " + $0.0 + " ") }
        guard let best = matches.max(by: { $0.0.count < $1.0.count }) else { return nil }
        let name = best.0.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return (name, best.1)
    }
}
