import Foundation
import Testing
@testable import ClickBaitCore

struct AssistantResponseTests {
    @Test func decodesDocumentedShape() throws {
        let json = #"{"speech":"Click the Share button in the top right.","pointers":[{"x":1180,"y":42,"label":"Share"}]}"#
        let response = try JSONDecoder().decode(AssistantResponse.self, from: Data(json.utf8))
        #expect(response == AssistantResponse(
            speech: "Click the Share button in the top right.",
            pointers: [Pointer(x: 1180, y: 42, label: "Share")]
        ))
    }
}
