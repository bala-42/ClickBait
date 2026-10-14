import Testing
@testable import ClickBaitCore

/// Voice → pointer: which spoken questions may be pointed at from the element list when
/// they name no target, and which picks are kept (2026-10-14: rambles pointed at random controls).
struct VoicePointerTests {
    private let ramble = "okay so I moved the folder and now when I go there it should bring me back to the window where I was but it keeps landing somewhere else and the chat is wrong too"

    @Test func shortWhereQuestionsMayPickFromTheList() {
        #expect(InstantAnswer.allowsUnnamedPick("where do I type my message?"))
        #expect(InstantAnswer.allowsUnnamedPick("which button saves this?"))
        #expect(InstantAnswer.allowsUnnamedPick("what do I click to send it"))
    }

    @Test func rambleThatMerelySaysWhereDoesNot() {
        #expect(ImpliedPointer.isLocating(ramble))  // why it slipped through before
        #expect(!InstantAnswer.allowsUnnamedPick(ramble))
    }

    @Test func howToAndPlainQuestionsDoNot() {
        #expect(!InstantAnswer.allowsUnnamedPick("show me how to make a new folder"))
        #expect(!InstantAnswer.allowsUnnamedPick("what does this error mean"))
    }

    @Test func aPickMustShareAWordWithTheQuestion() {
        #expect(InstantAnswer.unnamedPick("Message", fits: "where do I type my message?"))
        #expect(InstantAnswer.unnamedPick("Save", fits: "which button saves this?"))
        #expect(InstantAnswer.unnamedPick("Send", fits: "what do I click to send it"))
        // The model settling for any control: refused, the screenshot answers instead.
        #expect(!InstantAnswer.unnamedPick("Split pane", fits: "where do I type my message?"))
        #expect(!InstantAnswer.unnamedPick("Terminal", fits: "which button saves this?"))
        #expect(!InstantAnswer.unnamedPick("Anything", fits: "where do I click?"))  // nothing left to match
    }

    @Test func namedTargetsAreUnchanged() {
        #expect(InstantAnswer.locateTargets(in: "where's the share button") == ["share"])
        #expect(InstantAnswer.pick("Share", fits: "share"))
    }

    @Test func whereToTypeIsAnsweredFromTheCaret() {
        #expect(InstantAnswer.asksWhereToType("where do I type my message?"))  // the question HeyClicky got right
        #expect(InstantAnswer.asksWhereToType("Where can I write my reply"))
        #expect(InstantAnswer.asksWhereToType("where's the input field"))
        #expect(InstantAnswer.asksWhereToType("show me the text box"))
        #expect(!InstantAnswer.asksWhereToType("where's the share button"))
        #expect(!InstantAnswer.asksWhereToType("what does this error mean"))
        #expect(!InstantAnswer.asksWhereToType(ramble + " where do I type"))  // too long to be the question
    }
}

/// A snap inside a whole-window element proves nothing (Terminal's text area holds every guess).
struct SnapConfirmTests {
    private func decision(_ reason: SnapDecision.Reason, width: Double, height: Double) -> SnapDecision {
        let candidate = SnapCandidate(role: "AXTextArea", label: "", frame: Rect(x: 0, y: -1108, width: width, height: height))
        return SnapDecision(point: Point(x: 10, y: 10), candidate: candidate, reason: reason, score: 0)
    }

    @Test func insideTerminalsWholeTextAreaIsNotConfirmed() {
        // Measured 2026-10-14: Terminal's AXTextArea, 1508 × 2090 pt.
        #expect(!Snapper.confirms(decision(.containingElement, width: 1508, height: 2090)))
    }

    @Test func insideAnOrdinaryFieldStillIs() {
        #expect(Snapper.confirms(decision(.containingElement, width: 700, height: 30)))   // a wide text field
        #expect(Snapper.confirms(decision(.containingElement, width: 300, height: 600)))  // a tall sidebar
    }

    @Test func aLabelMatchAlwaysIs() {
        #expect(Snapper.confirms(decision(.labelMatch, width: 1508, height: 2090)))
        #expect(!Snapper.confirms(SnapDecision(point: Point(x: 0, y: 0), candidate: nil, reason: .noCandidates, score: 0)))
    }
}
