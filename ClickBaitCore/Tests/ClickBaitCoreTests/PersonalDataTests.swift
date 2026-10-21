import Foundation
import Testing
@testable import ClickBaitCore

struct PersonalDataTests {
    @Test func findsIdentityNumbers() {
        #expect(PersonalData.contains("my SSN is 123-45-6789"))
        #expect(PersonalData.contains("NRIC S1234567D"))
        #expect(PersonalData.contains("passport k1234567 expires soon"))
        #expect(PersonalData.contains("IBAN GB29 NWBK 6016 1331 9268 19"))
        #expect(PersonalData.contains("GB29NWBK60161331926819"))
    }

    @Test func leavesOrdinaryWordsAlone() {
        #expect(!PersonalData.contains("Flight SQ321 at 9"))
        #expect(!PersonalData.contains("FY24 revenue growth forecast"))
        #expect(!PersonalData.contains("FY24 REVENUE GROWTH FORECAST"))
        #expect(!PersonalData.contains("RTX 4090 vs M4 Max"))
        #expect(!PersonalData.contains("error E12 in build 2024"))
    }

    @Test func memoryRefusesThem() {
        var memory = Memory(file: "")
        let day = Date(timeIntervalSince1970: 1_792_500_000)
        #expect(memory.add("My passport is K1234567", on: day) == .refusedSecret)
        #expect(memory.add("my NRIC is S1234567D", on: day) == .refusedSecret)
        #expect(memory.add("bank account 12345678", on: day) == .refusedSecret)
        #expect(memory.add("My team is Atlas", on: day) == .saved("My team is Atlas"))
    }

    @Test func searchWordsDropThem() {
        #expect(QueryScrubber.clean("passport K1234567 renewal fee") == "passport renewal fee")
        #expect(QueryScrubber.clean("FY24 revenue growth") == "FY24 revenue growth")
    }
}
