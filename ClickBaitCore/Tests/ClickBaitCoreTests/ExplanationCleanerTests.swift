import Testing
@testable import ClickBaitCore

struct ExplanationCleanerTests {
    @Test(arguments: [
        ("The highlighted text refers to amortization, which spreads a cost over time.", "Amortization, which spreads a cost over time."),
        ("The selected text means the payment is due monthly.", "The payment is due monthly."),
        ("This text is about the company's refund policy.", "The company's refund policy."),
        ("The highlighted text says that the meeting moved to Friday.", "The meeting moved to Friday."),
    ])
    func stripsTheLeadIn(_ input: String, _ expected: String) {
        #expect(ExplanationCleaner.clean(input) == expected)
    }

    @Test(arguments: [
        "Amortization spreads a cost over several years.",
        "The highlighted text is a quote from Shakespeare.",  // "is" alone: stripping would read badly
        "Highlighted items are shown in yellow.",
        "",
    ])
    func leavesEverythingElse(_ input: String) {
        #expect(ExplanationCleaner.clean(input) == input)
    }

    @Test func stripsSnipLeadIns() {
        #expect(ExplanationCleaner.clean("The circled area shows a Python list comprehension.") == "A Python list comprehension.")
        #expect(ExplanationCleaner.clean("The area outlined in red is about tax brackets.") == "Tax brackets.")
        #expect(ExplanationCleaner.clean("The image contains a bar chart of sales.") == "A bar chart of sales.")
        #expect(ExplanationCleaner.clean("A bar chart of sales by month.") == "A bar chart of sales by month.")
        // Real qwen2.5vl:7b reply to a boxed snip.
        #expect(ExplanationCleaner.clean("The red outline highlights a ticket number and agenda items.") == "A ticket number and agenda items.")
    }
}
