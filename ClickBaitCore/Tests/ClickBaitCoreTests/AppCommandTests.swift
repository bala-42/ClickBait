import Testing
@testable import ClickBaitCore

struct AppCommandTests {
    private func parse(_ text: String) -> ActionRequest? {
        CommandParser.parse(text, allowedShortcuts: [])
    }

    @Test(arguments: [
        ("Make a note: call the dentist.", ActionRequest(name: "make_note", detail: "Call the dentist")),
        ("Make a note that the meeting moved to Friday", ActionRequest(name: "make_note", detail: "The meeting moved to Friday")),
        ("Take a note saying buy oat milk and eggs", ActionRequest(name: "make_note", detail: "Buy oat milk and eggs")),
        ("Jot down Sam's number is in the email", ActionRequest(name: "make_note", detail: "Sam's number is in the email")),
        ("Remind me to send the invoice.", ActionRequest(name: "add_reminder", detail: "Send the invoice")),
        ("Add a reminder to call Mum", ActionRequest(name: "add_reminder", detail: "Call Mum")),
        ("Set a reminder: renew passport", ActionRequest(name: "add_reminder", detail: "Renew passport")),
    ])
    func notesAndReminders(_ text: String, _ expected: ActionRequest) {
        #expect(parse(text) == expected)
    }

    @Test(arguments: [
        ("Pause.", "media", "play_pause"), ("Play the music", "media", "play_pause"), ("Resume", "media", "play_pause"),
        ("Next song", "media", "next"), ("Skip this track", "media", "next"), ("Previous track", "media", "previous"),
        ("Go back a song", "media", "previous"),
        ("Take a screenshot.", "screenshot", "full"), ("Screenshot this window", "screenshot", "window"),
        ("Take a screenshot of an area", "screenshot", "area"),
    ])
    func mediaAndScreenshots(_ text: String, _ name: String, _ argument: String) {
        #expect(parse(text) == ActionRequest(name: name, argument: argument))
    }

    @Test func finderAndDesktop() {
        #expect(parse("Open a new Finder window") == ActionRequest(name: "finder_window"))
        #expect(parse("Show desktop") == ActionRequest(name: "show_desktop"))
        #expect(parse("Show me the Desktop folder") == ActionRequest(name: "open_place", argument: "desktop"))
    }

    @Test(arguments: [
        "What's a good note-taking app?", "How do I take a screenshot?", "Play with this setting", "Next, open the file menu",
        "Where are my notes?", "Is there a reminder app?",
    ])
    func notCommands(_ text: String) {
        #expect(parse(text) == nil)
    }

    @Test func resolution() {
        let resolve = { (request: ActionRequest) in ActionCatalog.resolve(request, allowedShortcuts: []) }
        #expect(resolve(ActionRequest(name: "make_note", detail: "Buy milk / eggs")) == .success(.makeNote("Buy milk / eggs")))
        #expect(resolve(ActionRequest(name: "make_note")) == .failure(.missingArgument("write in the note")))
        #expect(resolve(ActionRequest(name: "media", argument: "next")) == .success(.media(.next)))
        #expect(resolve(ActionRequest(name: "screenshot", argument: "area")) == .success(.screenshot(.area)))
    }
}
