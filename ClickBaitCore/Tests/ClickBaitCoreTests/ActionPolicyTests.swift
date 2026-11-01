import Testing
@testable import ClickBaitCore

/// The user's rules (2026-10-20): clear words are the approval except binning and quitting;
/// a guessed order asks before it changes anything.
struct ActionPolicyTests {
    @Test func clearOrdersRunExceptTrashAndQuit() {
        #expect(ActionPolicy.decide(.quitApp("Safari"), from: .clearOrder) == .ask)
        #expect(ActionPolicy.decide(.file(.moveToTrash), from: .clearOrder) == .ask)
        for action: ResolvedAction in [.openApp("Notes"), .file(.rename(to: "Q3")), .file(.moveTo(.documents)),
                                       .runShortcut("Focus"), .setWiFi(false), .lockScreen, .makeNote("milk"),
                                       .setVolume(percent: 30)] {
            #expect(ActionPolicy.decide(action, from: .clearOrder) == .run, "\(action)")
        }
    }

    @Test func guessedOrdersAskBeforeChangingAnything() {
        for action: ResolvedAction in [.openApp("Notes"), .quitApp("Safari"), .makeNote("milk"), .addReminder("call mum"),
                                       .setVolume(percent: 30), .setMuted(true), .setDarkMode(true), .setWiFi(true),
                                       .newFolder(in: nil, name: nil), .runShortcut("Focus"), .lockScreen, .sleepDisplay,
                                       .file(.compress), .file(.copyTo(.desktop)), .file(.moveToTrash)] {
            #expect(ActionPolicy.decide(action, from: .modelGuess) == .ask, "\(action)")
        }
    }

    @Test func lookingRunsEvenWhenGuessed() {
        for action: ResolvedAction in [.screenshot(.full), .media(.playPause), .openPlace(.downloads), .newFinderWindow, .showDesktop] {
            #expect(ActionPolicy.decide(action, from: .modelGuess) == .run, "\(action)")
        }
    }

    @Test func everyAskedActionHasItsOwnQuestion() {
        let asked: [ResolvedAction] = [.openApp("Notes"), .makeNote("milk"), .addReminder("call mum"), .setVolume(percent: 30),
                                       .setMuted(false), .setDarkMode(false), .setWiFi(true), .newFolder(in: .downloads, name: "X"),
                                       .file(.compress), .file(.merge), .file(.shrink(toBytes: nil)), .file(.convert(to: .png)),
                                       .file(.copyTo(.desktop)), .file(.copyToFolder("Old"))]
        for action in asked {
            #expect(ActionCatalog.confirmationQuestion(for: action, fileCount: 2) != "Go ahead?", "\(action)")
        }
        #expect(ActionCatalog.confirmationQuestion(for: .openApp("Notes"), fileCount: nil) == "Open Notes?")
        #expect(ActionCatalog.confirmationQuestion(for: .newFolder(in: .downloads, name: "X"), fileCount: nil)
            == "Make a new folder called “X” in Downloads?")
    }
}
