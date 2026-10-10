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

struct SSEParserTests {
    @Test func parsesEventsSeparatedByBlankLines() {
        var parser = SSEParser()
        let lines = ["event: message_start", #"data: {"type":"message_start"}"#, "", ": ping", "data: a", "data: b", ""]
        let events = lines.compactMap { parser.consume(line: $0) }
        #expect(events == [
            .init(name: "message_start", data: #"{"type":"message_start"}"#),
            .init(name: nil, data: "a\nb"),
        ])
    }

    @Test func flushEmitsTrailingEventWithoutBlankLine() {
        var parser = SSEParser()
        _ = parser.consume(line: "event: message_stop")
        _ = parser.consume(line: #"data: {"type":"message_stop"}"#)
        #expect(parser.flush()?.name == "message_stop")
        #expect(parser.flush() == nil)
    }
}

struct AnthropicStreamDecoderTests {
    private func event(_ data: String) -> SSEParser.Event { .init(name: nil, data: data) }

    @Test func textDeltaYieldsText() throws {
        let output = try AnthropicStreamDecoder.decode(event(
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Click"}}"#))
        #expect(output == .text("Click"))
    }

    @Test func thinkingDeltaIsSkipped() throws {
        let output = try AnthropicStreamDecoder.decode(event(
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#))
        #expect(output == .none)
    }

    @Test func messageStopIsDone() throws {
        #expect(try AnthropicStreamDecoder.decode(event(#"{"type":"message_stop"}"#)) == .done)
    }

    @Test func refusalThrows() {
        #expect(throws: LLMError.refusal(category: "cyber")) {
            try AnthropicStreamDecoder.decode(event(
                #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}}"#))
        }
    }

    @Test func errorEventThrows() {
        #expect(throws: LLMError.invalidResponse("Overloaded")) {
            try AnthropicStreamDecoder.decode(event(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
        }
    }
}

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
    @Test func anthropicBodyUsesModelDefaultsAndSendsImageBeforeText() throws {
        let body = AnthropicProvider.messagesBody(for: ask, model: "claude-opus-5-5")
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 8192)
        #expect(body["output_config"] == nil)
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["thinking"] == nil)

        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(content[0]["source"] as? [String: String])
        #expect(source["media_type"] == "image/jpeg")
        #expect(source["data"] == "/9j/")
    }

    @Test func anthropicOmitsUnsupportedOptionsForHaiku() {
        let body = AnthropicProvider.messagesBody(for: ask, model: "claude-haiku-4-5")
        #expect(body["output_config"] == nil)
        #expect(body["fallbacks"] == nil)
    }

    @Test func anthropicRedMarkerTourKeepsImagesLabelsAndPixelCoordinates() throws {
        var tour = ask
        tour.markNames = ["Liver", "Gallbladder"]
        tour.markCount = 2

        let provider = AnthropicProvider(model: "claude-opus-5-5", apiKey: "sk-test")
        let body = AnthropicProvider.messagesBody(for: tour, model: provider.model)
        #expect(provider.coordinateScale == .pixels)
        #expect(body["system"] as? String == Prompt.marksSystem)
        #expect(body["stream"] as? Bool == false)

        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "web_search_20250305")
        #expect(tools[0]["name"] as? String == "web_search")
        #expect(tools[0]["max_uses"] as? Int == AnthropicProvider.webSearchMaxUses)
        #expect(tools[0]["allowed_callers"] as? [String] == ["direct"])

        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(content[0]["source"] as? [String: String])
        #expect(source["data"] == tour.screenshotJPEG.base64EncodedString())
        #expect((content.last?["text"] as? String)?.contains("Names: Liver, Gallbladder") == true)
        #expect((content.last?["text"] as? String)?.contains("Markers: 1–2") == true)
        #expect((body["max_tokens"] as? Int) == 16_384)
        #expect((body["output_config"] as? [String: String])?["effort"] == "high")
    }

    @Test func anthropicPartsLookRequestsScreenshotPixelCoordinates() throws {
        var parts = ask
        parts.listParts = true

        let body = AnthropicProvider.messagesBody(for: parts, model: "claude-opus-5-5")
        #expect(body["system"] as? String == Prompt.partsSystem)

        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect((content.last?["text"] as? String)?.contains("1280×831 pixels") == true)
        #expect(Prompt.partsSystem.contains("this image's pixels"))
    }

    @Test func anthropicAllowsMoreTimeForInternetModeFollowUps() {
        let local = OllamaProvider(model: "qwen3.5:9b")
        let internet = AnthropicProvider(model: "claude-opus-5-5", apiKey: "sk-test")

        #expect(local.timeout(for: .classifyRequest) == .seconds(3))
        #expect(internet.timeout(for: .classifyRequest) == .seconds(8))
        #expect(local.timeout(for: .labelTourParts) == .seconds(20))
        #expect(internet.timeout(for: .labelTourParts) == .seconds(90))
    }

    @Test func anthropicPauseTurnContinuationPreservesServerSearchBlocks() throws {
        let body = AnthropicProvider.messagesBody(for: {
            var request = ask
            request.markNames = ["Liver"]
            request.markCount = 3
            return request
        }(), model: "claude-opus-5-5")
        let assistantContent: [[String: Any]] = [
            ["type": "server_tool_use", "id": "srv_1", "name": "web_search", "input": ["query": "liver anatomy"]],
            ["type": "web_search_tool_result", "tool_use_id": "srv_1", "content": []],
        ]

        let continued = AnthropicProvider.continuationBody(body, assistantContent: assistantContent)
        let messages = try #require(continued["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages.last?["role"] as? String == "assistant")
        let replayed = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(replayed.map { $0["type"] as? String } == ["server_tool_use", "web_search_tool_result"])
        #expect(continued["tools"] as? [[String: Any]] != nil)
        #expect(continued["stream"] as? Bool == false)
    }

    @Test func anthropicDecodesFinalAndPausedMessages() throws {
        let pausedData = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "server_tool_use", "id": "srv_1", "name": "web_search", "input": [:]]],
            "stop_reason": "pause_turn",
        ])
        let paused = try AnthropicProvider.decodeMessageResponse(pausedData)
        #expect(paused.stopReason == "pause_turn")
        #expect(paused.content.first?["type"] as? String == "server_tool_use")

        let doneData = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": #"{"1":"Liver"}"#]],
            "stop_reason": "end_turn",
        ])
        let done = try AnthropicProvider.decodeMessageResponse(doneData)
        #expect(done.stopReason == "end_turn")
        #expect(done.content.first?["text"] as? String == #"{"1":"Liver"}"#)
    }

    @Test func anthropicRequestHeaders() throws {
        let request = try AnthropicProvider(model: "claude-opus-5-5", apiKey: "sk-test").makeMessagesRequest(ask)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")

        let haiku = try AnthropicProvider(model: "claude-haiku-4-5", apiKey: "sk-test").makeMessagesRequest(ask)
        #expect(haiku.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func anthropicWithoutKeyFailsBeforeAnyRequest() {
        #expect(throws: LLMError.missingAPIKey) {
            try AnthropicProvider(model: "claude-opus-5-5", apiKey: nil).makeMessagesRequest(ask)
        }
        #expect(throws: LLMError.missingAPIKey) {
            try AnthropicProvider(model: "claude-opus-5-5", apiKey: "").makeMessagesRequest(ask)
        }
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
        #expect(AnthropicProvider.error(status: 401, body: Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8), model: "m")
            == .http(status: 401, message: "invalid x-api-key"))
        #expect(LLMError.http(status: 401, message: "x").errorDescription == "The API key was rejected. Check it in Settings.")
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

        let anthropic = try #require(AnthropicProvider.messagesBody(for: followUp, model: "claude-opus-5-5")["messages"] as? [[String: Any]])
        #expect(anthropic.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(anthropic[0]["content"] as? String == "How do I share this?")
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
