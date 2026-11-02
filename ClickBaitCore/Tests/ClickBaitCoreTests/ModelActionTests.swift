import Foundation
import Testing
@testable import ClickBaitCore

struct ModelActionTests {
    @Test func parsesTheProposedAction() {
        let raw = #"{"speech": "Moving them to Documents.", "pointers": [], "action": {"name": "move_to", "argument": "documents"}}"#
        #expect(ResponseParser.parse(raw, imageWidth: 100, imageHeight: 100).response.action
                == ActionRequest(name: "move_to", argument: "documents"))
        let volume = #"{"speech": "s", "action": {"name": "set_volume", "argument": 30}}"#
        #expect(ResponseParser.parse(volume, imageWidth: 100, imageHeight: 100).response.action
                == ActionRequest(name: "set_volume", argument: "30"))
        #expect(ResponseParser.parse(#"{"speech": "s", "action": "nope"}"#, imageWidth: 100, imageHeight: 100).response.action == nil)
    }

    @Test func riskyActionsNeedConfirmation() {
        #expect(ActionPolicy.decide(.file(.moveToTrash), from: .modelGuess) == .ask)
        #expect(ActionPolicy.decide(.file(.moveTo(.documents)), from: .modelGuess) == .ask)
        #expect(ActionPolicy.decide(.quitApp("Safari"), from: .modelGuess) == .ask)
        #expect(ActionPolicy.decide(.file(.compress(.together)), from: .modelGuess) == .ask)  // guessed: asks now (2026-10-20)
        #expect(ActionPolicy.decide(.openApp("Safari"), from: .modelGuess) == .ask)
        #expect(ActionPolicy.decide(.newFolder(in: .downloads, name: "X"), from: .modelGuess) == .ask)
        #expect(ActionCatalog.confirmationQuestion(for: .file(.moveTo(.documents)), fileCount: 3) == "Move the 3 selected items to Documents?")
    }

    @Test(arguments: [
        ("Tidy my downloads into a folder called Old", true), ("Chuck these in the bin", true), ("Please stash these in Documents", true),
        ("How do I move files?", false), ("Where is the share button", false), ("Can I rename this?", false),
        ("It's too loud", false), ("What is this?", false),
    ])
    func ordersVersusQuestions(_ text: String, _ isOrder: Bool) {
        #expect(CommandParser.looksLikeOrder(text) == isOrder)
    }

    @Test func yesAndNo() {
        #expect(CommandParser.confirmation("Yes.") == true)
        #expect(CommandParser.confirmation("Go ahead") == true)
        // "peek at it?" (2026-11-02): looking inside is a yes.
        #expect(CommandParser.confirmation("Peek") == true && CommandParser.confirmation("Take a peek.") == true)
        #expect(CommandParser.confirmation("No, cancel") == nil)
        #expect(CommandParser.confirmation("Cancel.") == false)
        #expect(CommandParser.confirmation("Move these to documents") == nil)
    }

    @Test func orderInterpretationIsTextOnly() {
        let request = AskRequest(question: "stash these in my documents", screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                                 context: ScreenContext(appName: "Finder"))
        var order = request
        order.interpretOrder = true
        #expect(Prompt.system(for: order) == Prompt.orderSystem)
        #expect(Prompt.userText(for: order) == #"The user said (frontmost app: Finder): "stash these in my documents""#)
        let body = OllamaProvider.chatBody(for: order, model: "m")
        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.last?["images"] == nil)
        #expect(ResponseParser.action(inReply: #"{"action": {"name": "trash"}}"#) == ActionRequest(name: "trash"))
        #expect(ResponseParser.action(inReply: #"{"action": null}"#) == nil)
    }
}
