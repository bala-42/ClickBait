import Foundation

/// Pills read in small letters; names keep their capitals (user's ask, 2026-10-25):
/// "Taking you to Safari" → "taking you to Safari", "I opened History" → "i opened History".
///
///     PillCase.lowered("Done. Saved it to Downloads", names: [])  // "done. saved it to Downloads"
public enum PillCase {
    /// Mac apps, places and menus that keep their capital even first in a sentence; the app
    /// adds every installed app's name.
    public static let macNames: Set<String> = [
        "Finder", "Safari", "Chrome", "Google", "Claude", "ClickBait", "Settings", "System", "History", "Downloads",
        "Documents", "Desktop", "Applications", "Bookmarks", "Preferences", "Mail", "Messages", "Notes", "Photos",
        "Music", "Calendar", "Reminders", "Preview", "Terminal", "Xcode", "Slack", "YouTube", "Gmail", "Spotify",
        "Mac", "Dock", "Spotlight", "Siri", "AirDrop", "iCloud", "Apple", "Wi-Fi", "Bluetooth", "Trash",
        "Control", "Centre", "Center", "Mission", "Launchpad", "Firefox", "Arc", "Zoom", "Word", "Excel", "Pages",
        "Numbers", "Keynote", "FaceTime", "WhatsApp", "Telegram", "Discord", "Notion", "Figma", "GitHub",
        "Ollama", "Gemma", "Option", "Command", "Accessibility", "Microphone", "Screen", "Recording", "Camera",
        "QuickTime", "Studio", "Lookup", "Shelf", "Vision", "Memory",
        // Days and months are names too: "Friday works?" keeps its capital.
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
        "November", "December",
    ]

    public static func lowered(_ text: String, names: Set<String> = []) -> String {
        var out = ""
        var sentenceStart = true
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            out += fixed(word, start: sentenceStart, names: names)
            sentenceStart = false
            word = ""
        }
        for character in text {
            if character.isLetter || character.isNumber || "'’-".contains(character) {
                word.append(character)
            } else {
                flush()
                out.append(character)
                if ".!?…\n".contains(character) { sentenceStart = true }
            }
        }
        flush()
        return out
    }

    private static func fixed(_ word: String, start: Bool, names: Set<String>) -> String {
        let letters = word.filter(\.isLetter)
        // "I", "I'm", "I'll": small, as the look asks.
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return word.lowercased() }
        // Abbreviations (PDF, OCR) and inner capitals (iPhone, YouTube, ClickBait) are names.
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return word }
        if letters.dropFirst().contains(where: \.isUppercase) { return word }
        guard let first = word.first, first.isUppercase else { return word }
        // A capital mid-sentence is a name; first in a sentence only when it's a known one.
        if !start || macNames.contains(word) || names.contains(word) { return word }
        return word.lowercased()
    }
}
