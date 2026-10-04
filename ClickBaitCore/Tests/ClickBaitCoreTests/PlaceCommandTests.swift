import Testing
@testable import ClickBaitCore

struct PlaceCommandTests {
    private func parse(_ text: String) -> ActionRequest? {
        CommandParser.parse(text, allowedShortcuts: [])
    }

    @Test(arguments: [
        ("Make a new folder.", ActionRequest(name: "make_folder")),
        ("New folder", ActionRequest(name: "make_folder")),
        ("Make a new folder in Downloads called Receipts.", ActionRequest(name: "make_folder", argument: "downloads", detail: "Receipts")),
        ("Create a folder on the desktop named Tax 2026, please", ActionRequest(name: "make_folder", argument: "desktop", detail: "Tax 2026")),
        ("make a folder in my documents folder", ActionRequest(name: "make_folder", argument: "documents")),
        ("Make a new folder in iCloud Drive called Shared Stuff", ActionRequest(name: "make_folder", argument: "icloud_drive", detail: "Shared Stuff")),
        ("Put these in a new folder called Trip", ActionRequest(name: "new_folder", detail: "Trip")),
        ("Move them into a folder", ActionRequest(name: "new_folder")),
    ])
    func folders(_ text: String, _ expected: ActionRequest) {
        #expect(parse(text) == expected)
    }

    @Test(arguments: [
        ("Open Downloads", ActionRequest(name: "open_place", argument: "downloads")),
        ("Open my Documents folder.", ActionRequest(name: "open_place", argument: "documents")),
        ("Go to the desktop", ActionRequest(name: "open_place", argument: "desktop")),
        ("Open the music folder", ActionRequest(name: "open_place", argument: "music")),
        ("Show me the Desktop folder", ActionRequest(name: "open_place", argument: "desktop")),
        ("Open Music", ActionRequest(name: "open_app", argument: "music")),  // the app
        ("Open Safari", ActionRequest(name: "open_app", argument: "safari")),
    ])
    func opening(_ text: String, _ expected: ActionRequest) {
        #expect(parse(text) == expected)
    }

    @Test(arguments: [
        ("Move these to Documents.", ActionRequest(name: "move_to", argument: "documents")),
        ("Copy this to the desktop", ActionRequest(name: "copy_to", argument: "desktop")),
        ("Move the selected files into my Downloads folder", ActionRequest(name: "move_to", argument: "downloads")),
        ("Move these to the Trash", ActionRequest(name: "trash")),
        ("Rename this to Invoice March.", ActionRequest(name: "rename", detail: "Invoice March")),
        ("rename it Holiday Photos", ActionRequest(name: "rename", detail: "Holiday Photos")),
        ("Rename the file as \"Final draft\"", ActionRequest(name: "rename", detail: "Final draft")),
        ("Rename", ActionRequest(name: "rename")),
    ])
    func movingAndRenaming(_ text: String, _ expected: ActionRequest) {
        #expect(parse(text) == expected)
    }

    @Test func resolution() {
        let resolve = { (request: ActionRequest) in ActionCatalog.resolve(request, allowedShortcuts: []) }
        #expect(resolve(ActionRequest(name: "make_folder", argument: "downloads", detail: "Receipts")) == .success(.newFolder(in: .downloads, name: "Receipts")))
        #expect(resolve(ActionRequest(name: "make_folder")) == .success(.newFolder(in: nil, name: nil)))
        #expect(resolve(ActionRequest(name: "open_place", argument: "desktop")) == .success(.openPlace(.desktop)))
        #expect(resolve(ActionRequest(name: "move_to", argument: "documents")) == .success(.file(.moveTo(.documents))))
        #expect(resolve(ActionRequest(name: "rename", detail: "Invoice")) == .success(.file(.rename(to: "Invoice"))))
        #expect(resolve(ActionRequest(name: "rename")) == .failure(.missingArgument("rename it to")))
        // Names that would escape the folder or hide the file are refused.
        #expect(resolve(ActionRequest(name: "rename", detail: "../etc/passwd")) == .failure(.invalidArgument("“../etc/passwd” can't be used as a name")))
        #expect(resolve(ActionRequest(name: "make_folder", detail: ".hidden")) == .failure(.invalidArgument("“.hidden” can't be used as a name")))
        #expect(resolve(ActionRequest(name: "make_folder", argument: "narnia")) == .failure(.invalidArgument("I don't know the folder “narnia”")))
    }
}

struct FolderCommandTests {
    private func parse(_ text: String) -> ActionRequest? {
        CommandParser.parse(text, allowedShortcuts: [])
    }

    @Test(arguments: [
        ("Move these into Receipts.", ActionRequest(name: "move_to", argument: "Receipts")),
        ("Move these into the receipts folder", ActionRequest(name: "move_to", argument: "receipts")),
        ("Put them in the new folder", ActionRequest(name: "move_to", argument: "new folder")),
        ("Copy this into Tax 2026", ActionRequest(name: "copy_to", argument: "Tax 2026")),
        ("Move these to Documents", ActionRequest(name: "move_to", argument: "documents")),
        ("Put these in a new folder", ActionRequest(name: "new_folder")),
        ("Move these to the Trash", ActionRequest(name: "trash")),
    ])
    func intoFolders(_ text: String, _ expected: ActionRequest) {
        #expect(parse(text) == expected)
    }

    @Test func resolution() {
        let resolve = { (request: ActionRequest) in ActionCatalog.resolve(request, allowedShortcuts: []) }
        #expect(resolve(ActionRequest(name: "move_to", argument: "Receipts")) == .success(.file(.moveToFolder("Receipts"))))
        #expect(resolve(ActionRequest(name: "move_to", argument: "the untitled folder")) == .success(.file(.moveToFolder("new folder"))))
        #expect(resolve(ActionRequest(name: "copy_to", argument: "downloads")) == .success(.file(.copyTo(.downloads))))
        #expect(resolve(ActionRequest(name: "move_to", argument: "../secret")) == .failure(.invalidArgument("“../secret” isn't a folder name I can use")))
    }
}
