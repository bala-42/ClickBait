import Foundation
import Testing
@testable import ClickBaitCore

struct ActionCatalogTests {
    private let allowed = ["Focus Time", "Send ETA"]

    private func resolve(_ name: String, _ argument: String? = nil) -> Result<ResolvedAction, ActionError> {
        ActionCatalog.resolve(ActionRequest(name: name, argument: argument), allowedShortcuts: allowed)
    }

    @Test func resolvesBuiltIns() {
        #expect(resolve("open_app", "Safari") == .success(.openApp("Safari")))
        #expect(resolve("QUIT_APP", " Music ") == .success(.quitApp("Music")))
        #expect(resolve("mute") == .success(.setMuted(true)))
        #expect(resolve("unmute") == .success(.setMuted(false)))
        #expect(resolve("dark_mode") == .success(.setDarkMode(true)))
        #expect(resolve("light_mode") == .success(.setDarkMode(false)))
    }

    @Test func volumeIsParsedAndClamped() {
        #expect(resolve("set_volume", "30%") == .success(.setVolume(percent: 30)))
        #expect(resolve("set_volume", "250") == .success(.setVolume(percent: 100)))
        #expect(resolve("set_volume", "loud") == .failure(.invalidArgument("the volume should be a number from 0 to 100")))
    }

    @Test func missingArguments() {
        #expect(resolve("open_app") == .failure(.missingArgument("open")))
        #expect(resolve("run_shortcut", "  ") == .failure(.missingArgument("run")))
    }

    @Test func onlyAllowedShortcutsRunAndNamesAreMatchedFuzzily() {
        #expect(resolve("run_shortcut", "focus time") == .success(.runShortcut("Focus Time")))
        #expect(resolve("run_shortcut", "Delete Everything") == .failure(.shortcutNotAllowed("Delete Everything")))
    }

    @Test func unknownActionsAreRefused() {
        #expect(resolve("delete_files", "~/Downloads") == .failure(.unknown("delete_files")))
    }

}

struct CommandParserTests {
    private let allowed = ["Focus Time", "Send ETA"]

    private func parse(_ text: String) -> ActionRequest? {
        CommandParser.parse(text, allowedShortcuts: allowed)
    }

    @Test(arguments: [
        ("Open Safari.", "open_app", "safari"),
        ("Please open up the Notes app.", "open_app", "notes"),
        ("Can you launch System Settings?", "open_app", "system settings"),
        ("Hey ClickBait, open Spotify please", "open_app", "spotify"),
        ("Quit Music.", "quit_app", "music"),
        ("Close the Calendar app", "quit_app", "calendar"),
    ])
    func appOrders(_ text: String, _ name: String, _ argument: String) {
        #expect(parse(text) == ActionRequest(name: name, argument: argument))
    }

    @Test(arguments: [
        ("Volume 30.", "30"), ("Set the volume to twenty.", "20"), ("Turn the volume down to twenty five", "25"),
        ("Turn the sound up to 80 percent", "80"), ("Set volume to a hundred", "100"), ("Volume zero", "0"),
    ])
    func volumeOrders(_ text: String, _ level: String) {
        #expect(parse(text) == ActionRequest(name: "set_volume", argument: level))
    }

    @Test func muteAndAppearance() {
        #expect(parse("Mute.") == ActionRequest(name: "mute"))
        #expect(parse("Unmute the sound") == ActionRequest(name: "unmute"))
        #expect(parse("Switch to dark mode.") == ActionRequest(name: "dark_mode"))
        #expect(parse("Dark mode") == ActionRequest(name: "dark_mode"))
        #expect(parse("Turn off dark mode") == ActionRequest(name: "light_mode"))
        #expect(parse("Light mode please") == ActionRequest(name: "light_mode"))
    }

    @Test func shortcuts() {
        #expect(parse("Run my Focus Time shortcut.") == ActionRequest(name: "run_shortcut", argument: "Focus Time"))
        #expect(parse("Run send ETA") == ActionRequest(name: "run_shortcut", argument: "Send ETA"))
        #expect(parse("Focus time.") == ActionRequest(name: "run_shortcut", argument: "Focus Time"))  // just the name
        #expect(parse("Run Delete Everything") == nil)  // not allowed: falls through to a normal answer
        #expect(CommandParser.parse("Run Focus Time", allowedShortcuts: []) == nil)
    }

    @Test(arguments: [
        "How do I open Safari?", "What's the volume?", "Where is dark mode?", "Can I open two windows?",
        "Is dark mode on?", "Should I quit Music?", "Why won't Safari open?",
    ])
    func questionsAreNeverOrders(_ text: String) {
        #expect(parse(text) == nil)
    }

    @Test(arguments: ["Turn the volume down", "Set the volume to 150", "Open", "Tell me about this page", ""])
    func incompleteOrUnrelatedAreNotOrders(_ text: String) {
        #expect(parse(text) == nil)
    }
}

struct SystemAndFileCommandTests {
    private func parse(_ text: String) -> ActionRequest? {
        CommandParser.parse(text, allowedShortcuts: [])
    }

    @Test(arguments: [
        ("Turn on Wi-Fi.", "wifi_on"), ("Turn the wifi off", "wifi_off"), ("WiFi off", "wifi_off"), ("Disable Wi-Fi", "wifi_off"),
        ("Lock the screen", "lock_screen"), ("Lock my Mac.", "lock_screen"), ("Turn off the display", "sleep_display"),
    ])
    func systemOrders(_ text: String, _ name: String) {
        #expect(parse(text) == ActionRequest(name: name))
    }

    @Test(arguments: [
        ("Compress these files.", "compress", nil), ("Zip them", "compress", nil), ("Zip this folder", "compress", nil),
        ("Merge these PDFs.", "merge", nil), ("Merge.", "merge", nil), ("Zip", "compress", nil), ("Combine the selected images", "merge", nil),
        ("Convert these to JPEG", "convert_images", "jpeg"), ("Make them PNGs", "convert_images", "png"),
        ("Put these in a new folder", "new_folder", nil),
        ("Delete these files", "trash", nil), ("Move these to the Trash", "trash", nil), ("Trash them", "trash", nil),
        ("Make these smaller", "shrink", nil), ("Reduce the size of this file", "shrink", nil), ("Shrink them", "shrink", nil),
        ("Optimize these images", "shrink", nil), ("Reduce the file size of these videos", "shrink", nil), ("Shrink", "shrink", nil),
    ] as [(String, String, String?)])
    func fileOrders(_ text: String, _ name: String, _ argument: String?) {
        #expect(parse(text) == ActionRequest(name: name, argument: argument))
    }

    @Test(arguments: [
        "Delete", "Make it bigger", "Turn the page", "How do I compress these files?", "What does wifi do?",
        "Delete the last word", "Remove the background", "Make it bigger", "Reduce the volume",
    ])
    func notFileOrSystemOrders(_ text: String) {
        #expect(parse(text) == nil)
    }

    @Test func resolution() {
        #expect(ActionCatalog.resolve(ActionRequest(name: "convert_images", argument: "jpg"), allowedShortcuts: [])
            == .success(.file(.convertImages(to: .jpeg))))
        #expect(ActionCatalog.resolve(ActionRequest(name: "convert_images", argument: "gif"), allowedShortcuts: [])
            == .failure(.invalidArgument("I can convert images to JPEG or PNG")))
        #expect(ActionCatalog.resolve(ActionRequest(name: "trash"), allowedShortcuts: []) == .success(.file(.moveToTrash)))
        #expect(ActionCatalog.resolve(ActionRequest(name: "shrink"), allowedShortcuts: []) == .success(.file(.shrink)))
    }

    @Test func outputNamesNeverOverwrite() {
        #expect(OutputName.unique(base: "Merged", extension: "pdf", existing: []) == "Merged.pdf")
        #expect(OutputName.unique(base: "Merged", extension: "pdf", existing: ["Merged.pdf", "Merged 2.pdf"]) == "Merged 3.pdf")
        #expect(OutputName.unique(base: "New Folder", extension: "", existing: ["New Folder"]) == "New Folder 2")
    }
}
