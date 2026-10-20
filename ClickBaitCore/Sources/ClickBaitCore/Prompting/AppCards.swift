import Foundation

/// C4: short notes on common Mac apps, so the model answers "how do I … in Notes" from the
/// real menus instead of guessing them (the idea of HeyClicky's per-app files, cut down for a
/// small local model, 2026-10-20). Only stable facts: menu paths and shortcuts that haven't
/// moved in years. One card at most per request, under `maxCharacters`.
///
/// A card is used when the request names its app the way the user's rule says ("in Notes",
/// "open Safari", "using Preview"; a plain word like "my notes" is not the app), and while
/// planning a walkthrough, for the app in front.
///
///     AppCards.card(for: "how do I make a checklist in Notes", frontmost: "Finder", planning: false)
///     // (app: "Notes", text: "New note: File ▸ New Note (⌘N). …")
public enum AppCards {
    /// ~300 tokens: enough for the facts, small enough not to slow the answer.
    public static let maxCharacters = 1_200
    /// Written for macOS 26 (2026-10-20). Check a card when macOS moves a menu.
    public static let checked = "2026-10-20"

    public struct Card: Sendable {
        public let app: String
        /// Other names people use for it ("Chrome" for Google Chrome).
        public let aliases: [String]
        public let text: String
    }

    public static let all: [Card] = [
        Card(app: "Notes", aliases: ["Apple Notes"], text: """
            New note: File ▸ New Note (⌘N). New folder: File ▸ New Folder (⇧⌘N). Folders sidebar: View ▸ Show Folders.
            Checklist: Format ▸ Checklist (⇧⌘L). Table: Format ▸ Table (⌥⌘T). Headings and styles: the Aa button in the toolbar.
            Pin a note: File ▸ Pin Note. Lock a note: File ▸ Lock Note (asks for the notes password first).
            Attach a file: Edit ▸ Attach File (⇧⌘A), or drag it in. Share or collaborate: the Share button in the toolbar.
            Search all notes: the search field at the top of the note list (⌥⌘F).
            Deleted notes stay in Recently Deleted for 30 days.
            """),
        Card(app: "Reminders", aliases: ["Apple Reminders"], text: """
            New reminder: File ▸ New Reminder (⌘N), or click the empty row at the end of a list. New list: File ▸ New List \
            (⇧⌘N), or Add List at the bottom of the sidebar.
            Date, time, location, flag, priority: the ⓘ button that appears on a reminder when you point at it.
            Subtask: Edit ▸ Indent Reminder (⌘]). Show done ones: View ▸ Show Completed.
            Smart lists in the sidebar: Today, Scheduled, All, Flagged, Completed.
            Share a list: right-click it in the sidebar ▸ Share List.
            """),
        Card(app: "Finder", aliases: [], text: """
            New window ⌘N, new tab ⌘T, new folder ⇧⌘N. Rename: select it and press Return. Get Info ⌘I. Quick Look: Space.
            Move to Trash ⌘⌫; Empty Trash ⇧⌘⌫ (Finder ▸ Empty Trash).
            Go menu: Desktop ⇧⌘D, Documents ⇧⌘O, Downloads ⌥⌘L, Home ⇧⌘H, Applications ⇧⌘A, Go to Folder ⇧⌘G.
            Views: icons ⌘1, list ⌘2, columns ⌘3, gallery ⌘4. Path bar: View ▸ Show Path Bar (⌥⌘P). Preview pane ⇧⌘P.
            Hidden files: ⇧⌘. (period). Zip: right-click ▸ Compress. Tags: right-click ▸ Tags.
            """),
        Card(app: "Safari", aliases: [], text: """
            New tab ⌘T, new window ⌘N, private window ⇧⌘N. Reopen a closed tab: History ▸ Reopen Last Closed Tab (⇧⌘T).
            Clear history: History ▸ Clear History…. Downloads: View ▸ Show Downloads (⌥⌘L). Reader: View ▸ Show Reader (⇧⌘R).
            Bookmark: Bookmarks ▸ Add Bookmark (⌘D). Find on page ⌘F. Zoom ⌘+ / ⌘−.
            Settings: Safari ▸ Settings (⌘,): General (homepage), Search (search engine), Extensions, Websites (permissions).
            Saved passwords are in the Passwords app. Share a page: the Share button in the toolbar.
            """),
        Card(app: "Google Chrome", aliases: ["Chrome"], text: """
            New tab ⌘T, new window ⌘N, incognito window ⇧⌘N. Reopen a closed tab ⇧⌘T.
            Clear browsing data: Chrome ▸ Delete Browsing Data… (⇧⌘⌫; older versions call it Clear Browsing Data…).
            History ⌘Y, Downloads ⇧⌘J, Bookmark ⌘D, bookmarks bar ⇧⌘B. Find on page ⌘F.
            Settings ⌘, (search engine, passwords, privacy). Extensions: the puzzle-piece button, or chrome://extensions.
            Profiles: the profile picture at the top right.
            """),
        Card(app: "Mail", aliases: ["Apple Mail"], text: """
            New message ⌘N. Reply ⌘R, Reply All ⇧⌘R, Forward ⇧⌘F. Attach files: File ▸ Attach Files (⇧⌘A), or drag them in.
            Mark unread: Message ▸ Mark ▸ as Unread (⇧⌘U). Junk: Message ▸ Move to Junk. Flag: Message ▸ Flag.
            Signatures: Mail ▸ Settings ▸ Signatures. Rules: Mail ▸ Settings ▸ Rules. Accounts: Mail ▸ Settings ▸ Accounts.
            Search: the search field at the top right of the window.
            ClickBait never sends mail: the user checks the message and clicks Send.
            """),
        Card(app: "Calendar", aliases: ["Apple Calendar", "iCal"], text: """
            New event: File ▸ New Event (⌘N), or double-click a time. New calendar: File ▸ New Calendar.
            Views: Day ⌘1, Week ⌘2, Month ⌘3, Year ⌘4. Today: View ▸ Go to Today (⌘T).
            Invite people: open the event and add Invitees. Repeat and alerts: in the event's details.
            Accounts: Calendar ▸ Settings ▸ Accounts. Default alerts: Calendar ▸ Settings ▸ Alerts.
            Show or hide calendars: the list in the sidebar (View ▸ Show Calendar List).
            """),
        Card(app: "Messages", aliases: ["iMessage"], text: """
            New message ⌘N. Search: the search field above the conversation list.
            Edit or unsend a sent iMessage: right-click it ▸ Edit or Undo Send (only for a few minutes).
            Send a file or photo: drag it in, or the + button left of the text field. Reply to one message: right-click ▸ Reply.
            Delete a conversation: right-click it ▸ Delete. Pin: right-click ▸ Pin.
            Account: Messages ▸ Settings ▸ iMessage.
            ClickBait never sends a message: the user presses Return.
            """),
        Card(app: "System Settings", aliases: ["System Preferences", "Settings"], text: """
            Fastest: the search field at the top of the sidebar.
            Appearance (Light, Dark, Auto), Wallpaper, Displays (resolution, Night Shift), Sound, Wi-Fi, Bluetooth,
            Notifications, Focus, Battery, Lock Screen, Desktop & Dock (Dock size, hide the Dock, hot corners),
            Control Center, Keyboard (shortcuts), Trackpad, Users & Groups.
            General ▸ Software Update, General ▸ Storage, General ▸ Login Items & Extensions, General ▸ AirDrop & Handoff.
            Privacy & Security: Screen & System Audio Recording, Microphone, Accessibility, Camera.
            Security and privacy switches are the user's to change: show where, never change them.
            """),
        Card(app: "Preview", aliases: [], text: """
            Markup toolbar: View ▸ Show Markup Toolbar (⇧⌘A). Sign: Tools ▸ Annotate ▸ Signature, or the Sign button in it.
            Rotate: Tools ▸ Rotate Left (⌘L) / Rotate Right (⌘R). Crop: drag a selection, then Tools ▸ Crop (⌘K).
            Resize an image: Tools ▸ Adjust Size. Convert: File ▸ Export… (choose JPEG, PNG, HEIC, PDF). PDF: File ▸ Export as PDF.
            Combine PDFs: View ▸ Thumbnails, then drag pages or other PDFs into the sidebar.
            Fill a form: click into its fields. Find text ⌘F.
            """),
        Card(app: "Music", aliases: ["Apple Music", "iTunes"], text: """
            Play or pause: Space. Next ⌘→, previous ⌘←. Shuffle and repeat: Controls ▸ Shuffle / Repeat.
            New playlist: File ▸ New ▸ Playlist (⌘N). Add a song to it: right-click the song ▸ Add to Playlist.
            Import files: File ▸ Import (⌘O). Equalizer: Window ▸ Equalizer (⌥⌘E).
            Lyrics and Up Next: the buttons at the top right of the window.
            Search: the search field at the top of the sidebar.
            """),
        Card(app: "Photos", aliases: ["Apple Photos", "iPhoto"], text: """
            Import: File ▸ Import (⇧⌘I). Export: File ▸ Export ▸ Export Photos (⇧⌘E), or Export Unmodified Original.
            Edit: select a photo and press Return, or click Edit: Adjust, Filters, Crop. Revert: Image ▸ Revert to Original.
            New album: File ▸ New Album (⌘N). Hide: Image ▸ Hide Photo (⌘L).
            Delete: ⌫; deleted photos stay in Recently Deleted for 30 days.
            iCloud Photos: Photos ▸ Settings ▸ iCloud. Search: the search field in the toolbar.
            """),
        Card(app: "TextEdit", aliases: [], text: """
            New document ⌘N, save ⌘S. Plain text: Format ▸ Make Plain Text (⇧⌘T); back to rich text: Format ▸ Make Rich Text.
            Fonts ⌘T. Find and replace: Edit ▸ Find ▸ Find and Replace (⌥⌘F). PDF: File ▸ Export as PDF.
            New documents as plain text: TextEdit ▸ Settings ▸ New Document ▸ Plain Text.
            """),
        Card(app: "Terminal", aliases: [], text: """
            New window ⌘N, new tab ⌘T. Clear the screen ⌘K. Stop a running command ⌃C.
            Colours and font: Terminal ▸ Settings ▸ Profiles. Default shell is zsh (~/.zshrc).
            ClickBait never runs commands: give the exact command in "code" for the user to copy and run.
            """),
        Card(app: "Maps", aliases: ["Apple Maps"], text: """
            Search: the field at the top of the sidebar. Directions: the Directions button (⌘R), then pick driving, walking,
            transit or cycling. Share a place or route: the Share button. Satellite or transit view: the map-mode button at
            the top right. Favourites and Guides: in the sidebar.
            """),
    ]

    /// The card for a request: the app it names ("in Notes", "open Safari"), or — while
    /// planning a walkthrough — the app in front. Nil when no card fits.
    public static func card(for question: String, frontmost: String?, planning: Bool) -> Card? {
        let names = all.flatMap { [$0.app] + $0.aliases }
        if let named = TutorialQuestion.locatingApp(in: question, apps: names) {
            return lookUp(named)
        }
        guard planning, let frontmost else { return nil }
        return lookUp(frontmost)
    }

    static func lookUp(_ name: String) -> Card? {
        all.first { card in ([card.app] + card.aliases).contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }

    /// How the card goes into the prompt.
    public static func block(_ card: Card) -> String {
        "About \(card.app) (reference: its menus and shortcuts; may be incomplete):\n\(card.text)"
    }
}
