import Testing
@testable import ClickBaitCore

/// Pills in small letters, names kept (user's ask, 2026-10-25).
struct PillCaseTests {
    @Test func ordinaryWordsGoSmall() {
        #expect(PillCase.lowered("Taking you to Safari") == "taking you to Safari")
        #expect(PillCase.lowered("Compressed 3 files") == "compressed 3 files")
        #expect(PillCase.lowered("Done. Saved it to Downloads.") == "done. saved it to Downloads.")
        #expect(PillCase.lowered("Show me the fixed code") == "show me the fixed code")
    }

    @Test func namesKeepTheirCapitals() {
        #expect(PillCase.lowered("Finder ▸ Go ▸ Downloads") == "Finder ▸ Go ▸ Downloads")
        #expect(PillCase.lowered("Settings ▸ General") == "Settings ▸ General")
        #expect(PillCase.lowered("Open History in Chrome") == "open History in Chrome")
        #expect(PillCase.lowered("Figlet is ready", names: ["Figlet"]) == "Figlet is ready")
        #expect(PillCase.lowered("PDF saved, ⌘V to paste") == "PDF saved, ⌘V to paste")
        #expect(PillCase.lowered("Ask ClickBait about YouTube on your iPhone") == "ask ClickBait about YouTube on your iPhone")
    }

    @Test func iIsSmall() {
        #expect(PillCase.lowered("I opened it, and I'm done") == "i opened it, and i'm done")
    }

    @Test func pillWordingFromThisSession() {
        #expect(PillCase.lowered("Convert 1 item to MP4?") == "convert 1 item to MP4?")
        #expect(PillCase.lowered("On it, in the dock") == "on it, in the dock")
        #expect(PillCase.lowered("Make smaller copies of 1 item under 50 MB?") == "make smaller copies of 1 item under 50 MB?")
        #expect(PillCase.lowered("Friday works?") == "Friday works?")
        #expect(PillCase.lowered("Do it") == "do it")
        #expect(PillCase.lowered("Opening Safari…") == "opening Safari…")
    }
}
