import Foundation
import Testing
@testable import ClickBaitCore

private let ask = AskRequest(
    question: "How do I share this?",
    screenshotJPEG: Data([0xFF, 0xD8, 0xFF]),
    screenshotWidth: 1280,
    screenshotHeight: 831,
    context: ScreenContext(appName: "Pages", windowTitle: "Report.pages")
)

struct OllamaStreamDecoderTests {
    @Test func decodesChunksAndDone() throws {
        let chunk = try OllamaStreamDecoder.decode(line: #"{"message":{"role":"assistant","content":"{\"spe"},"done":false}"#)
        #expect(chunk?.text == #"{"spe"#)
        #expect(chunk?.done == false)
        let last = try OllamaStreamDecoder.decode(line: #"{"message":{"role":"assistant","content":""},"done":true}"#)
        #expect(last?.done == true)
    }

    @Test func errorLineThrows() {
        #expect(throws: LLMError.invalidResponse("model is loading")) {
            try OllamaStreamDecoder.decode(line: #"{"error":"model is loading"}"#)
        }
    }

    @Test func blankLineIsIgnored() throws {
        #expect(try OllamaStreamDecoder.decode(line: "") == nil)
    }
}

struct RequestBuilderTests {
    @Test func secondaryRequestsHaveLocalDeadlines() {
        #expect(ProviderOperation.classifyRequest.timeout == .seconds(3))
        #expect(ProviderOperation.selectElement.timeout == .seconds(5))
        #expect(ProviderOperation.labelTourParts.timeout == .seconds(20))
    }

    @Test func ollamaBodyIsLocalJSONModeWithImage() throws {
        let request = try OllamaProvider(model: "qwen2.5vl:7b").makeChatRequest(ask)
        #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")

        let body = OllamaProvider.chatBody(for: ask, model: "qwen2.5vl:7b")
        #expect(body["format"] as? String == "json")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages[1]["images"] as? [String] == ["/9j/"])
    }

    @Test func ollamaModelMatching() {
        #expect(OllamaProvider.isInstalled("llava", among: ["llava:latest"]))
        #expect(OllamaProvider.isInstalled("qwen2.5vl:7b", among: ["qwen2.5vl:7b", "llama3.1:latest"]))
        #expect(!OllamaProvider.isInstalled("qwen2.5vl:7b", among: ["qwen2.5vl:3b"]))
    }

    @Test func userTextCarriesSizeContextAndQuestion() {
        let text = Prompt.userText(for: ask)
        #expect(text.contains("1280×831 pixels"))
        #expect(text.contains("Frontmost app: Pages"))
        #expect(text.contains("Window title: Report.pages"))
        #expect(!text.contains("Focused element"))
        #expect(text.hasSuffix("The user said: How do I share this?"))
    }

    @Test func userTextForHighlightedTextAsksForAnExplanation() {
        var request = ask
        request.question = ""
        request.selectedText = "Amortization is the spreading of payments over time."
        let text = Prompt.userText(for: request)
        #expect(text.contains("The user highlighted this text:\n<<<\nAmortization is the spreading of payments over time.\n>>>"))
        #expect(text.hasSuffix("Explain the highlighted text."))
        #expect(text.contains("Frontmost app: Pages"))
    }

    @Test func highlightedTextKeepsASpokenQuestion() {
        var request = ask
        request.question = "Is this good for me?"
        request.selectedText = "APR 24.9%"
        #expect(Prompt.userText(for: request).hasSuffix("The user said: Is this good for me?"))
    }

    @Test func longHighlightsAreCutOff() {
        var request = ask
        request.selectedText = String(repeating: "a", count: Prompt.maxSelectedCharacters + 500)
        let text = Prompt.userText(for: request)
        #expect(text.contains("[…cut off]"))
        #expect(!text.contains(String(repeating: "a", count: Prompt.maxSelectedCharacters + 1)))
    }

    @Test func errorsMapToPlainLanguage() {
        #expect(LLMError.http(status: 500, message: "x").errorDescription == "The model service returned an error (500): x")
        #expect(OllamaProvider.error(status: 404, body: Data(#"{"error":"model not found"}"#.utf8), model: "m") == .modelNotFound("m"))
    }
}

struct ConversationTests {
    @Test func historyKeepsTheFirstExchangeAndTheMostRecent() {
        var conversation = Conversation()
        for i in 1...15 { conversation.append(user: "q\(i)", assistantSpeech: "a\(i)") }
        let history = conversation.history
        #expect(history.count == Conversation.maxExchanges * 2)
        #expect(history.first == ChatTurn(role: .user, content: "q1"))
        #expect(history[2] == ChatTurn(role: .user, content: "q7"))
        #expect(history.last == .assistant(speech: "a15"))
    }

    @Test func assistantTurnsKeepTheirCode() {
        let turn = ChatTurn.assistant(speech: "Use:", code: "ls -la\npwd", language: "bash")
        let parsed = ResponseParser.parse(turn.content, imageWidth: 10, imageHeight: 10).response
        #expect(parsed.code == "ls -la\npwd")
        #expect(parsed.language == "bash")
    }

    @Test func assistantTurnsAreEscapedJSON() {
        let turn = ChatTurn.assistant(speech: "Click \"Share\".\nThen \\ done")
        #expect(turn.content == #"{"speech": "Click \"Share\".\nThen \\ done", "pointers": []}"#)
        #expect(ResponseParser.parse(turn.content, imageWidth: 10, imageHeight: 10).response.speech == "Click \"Share\".\nThen \\ done")
    }

    @Test func followUpPromptAndProviderMessages() throws {
        var conversation = Conversation()
        conversation.append(user: "How do I share this?", assistantSpeech: "Click Share.")
        let followUp = AskRequest(question: "And then?", screenshotJPEG: Data([1]), screenshotWidth: 10, screenshotHeight: 10,
                                  context: ScreenContext(), history: conversation.history)
        #expect(Prompt.userText(for: followUp).contains("Follow-up in the same conversation"))
        #expect(Prompt.userText(for: followUp).hasSuffix("The user said: And then?"))

        let ollama = try #require(OllamaProvider.chatBody(for: followUp, model: "m")["messages"] as? [[String: Any]])
        #expect(ollama.map { $0["role"] as? String } == ["system", "user", "assistant", "user"])
        #expect(ollama[1]["images"] == nil)       // old turns carry no screenshot
        #expect(ollama[3]["images"] != nil)       // the new message does
    }
}

struct TwoModelTests {
    @Test func textJobsGoToTheFastModel() throws {
        let provider = OllamaProvider(model: "qwen3.5:9b", fastModel: "qwen2.5vl:7b")
        var ask = AskRequest(question: "q", screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0, context: ScreenContext())
        #expect(provider.model(for: ask) == "qwen3.5:9b")
        ask.planTutorial = true
        #expect(provider.model(for: ask) == "qwen3.5:9b")  // plans: quality matters more
        ask.planTutorial = false
        ask.interpretOrder = true
        #expect(provider.model(for: ask) == "qwen2.5vl:7b")
        #expect(OllamaProvider(model: "m").model(for: ask) == "m")
        #expect(OllamaProvider(model: "m", fastModel: "").fastModel == nil)
    }

    @Test func qwen3SpeaksThousandths() throws {
        #expect(OllamaProvider(model: "qwen3.5:9b").coordinateScale == .thousandths)
        #expect(OllamaProvider(model: "qwen2.5vl:7b").coordinateScale == .pixels)
        // The body sent to Qwen 3.5 lists elements and asks for positions in 0–1000.
        var ask = AskRequest(question: "where's Share", screenshotJPEG: Data([1]), screenshotWidth: 1280, screenshotHeight: 800,
                             context: ScreenContext(), elements: [PromptElement(id: 1, kind: "button", label: "Share", x: 640, y: 400)])
        ask.coordinateScale = .thousandths
        let text = Prompt.userText(for: ask)
        #expect(text.contains("1: button \"Share\" at (500, 500)"))
        #expect(!text.contains("in screenshot pixels"))
    }

    @Test func thousandthsComeBackAsPixels() {
        let parsed = ResponseParser.parse(#"{"speech": "There.", "pointers": [{"x": 569, "y": 493, "label": "Jupiter"}], "parts": [{"x": 500, "y": 500, "label": "Sun"}]}"#,
                                          imageWidth: 1280, imageHeight: 887, scale: .thousandths).response
        #expect(abs(parsed.pointers[0].x - 728.3) < 0.5 && abs(parsed.pointers[0].y - 437.3) < 0.5)
        #expect(parsed.parts[0].x == 640 && parsed.parts[0].y == 443.5)
    }
}
