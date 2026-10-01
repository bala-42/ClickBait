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
    @Test func anthropicBodySendsImageBeforeTextWithLowEffortAndFallbacks() throws {
        let body = AnthropicProvider.messagesBody(for: ask, model: "claude-opus-5-5")
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["stream"] as? Bool == true)
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
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

    @Test func errorsMapToPlainLanguage() {
        #expect(AnthropicProvider.error(status: 401, body: Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8), model: "m")
            == .http(status: 401, message: "invalid x-api-key"))
        #expect(LLMError.http(status: 401, message: "x").errorDescription == "The API key was rejected. Check it in Settings.")
        #expect(OllamaProvider.error(status: 404, body: Data(#"{"error":"model not found"}"#.utf8), model: "m") == .modelNotFound("m"))
    }
}
