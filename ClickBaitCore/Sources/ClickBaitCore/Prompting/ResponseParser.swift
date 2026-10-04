import Foundation

/// Turns whatever the model sent into an `AssistantResponse`.
///
/// Models don't always follow the schema. This accepts code fences and chatter around
/// the JSON, numbers as strings, and the coordinate shapes vision models are trained
/// on (`"x": [x, y]`, `"point_2d": [x, y]`, `"bbox_2d": [x1, y1, x2, y2]`). If no usable
/// JSON is found it falls back to speech only — it never throws.
public enum ResponseParser {
    public struct Result: Equatable, Sendable {
        public var response: AssistantResponse
        /// True when the JSON was unusable and `speech` was salvaged from raw text.
        public var usedFallback: Bool
        /// Pointers that were present but unusable (no coordinates, off-image).
        public var droppedPointers: Int
    }

    public static let maxPointers = 3
    /// Coordinates this far outside the image (as a fraction of its size) are clamped
    /// rather than dropped: models round to their own internal resolution.
    public static let edgeTolerance = 0.03
    /// Points inside this many pixels of the top-left corner are a model filling in a
    /// placeholder ({"x": 0, "y": 0}), not a real answer — and snapping would otherwise
    /// land them on the window's close button.
    public static let placeholderCorner = 24.0
    static let fallbackSpeech = "Sorry, I couldn't work that out. Try asking again."

    /// `elements` is the numbered list the prompt offered: a pointer may name one by id.
    public static func parse(_ raw: String, imageWidth: Int, imageHeight: Int, elements: [PromptElement] = []) -> Result {
        guard let object = firstJSONObject(in: raw) else {
            return Result(response: AssistantResponse(speech: salvageSpeech(from: raw)), usedFallback: true, droppedPointers: 0)
        }

        let written = (object["speech"] as? String ?? object["answer"] as? String ?? object["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Positions never belong in the text (they'd show in the chat or be read aloud).
        let (speech, partsInText) = CoordinateScrubber.scrub(written)

        let rawPointers = (object["pointers"] ?? object["points"] ?? object["pointer"]).map(asArray) ?? []
        var pointers: [Pointer] = []
        var dropped = 0
        for entry in rawPointers {
            guard let dict = entry as? [String: Any],
                  let pointer = pointer(from: dict, imageWidth: imageWidth, imageHeight: imageHeight, elements: elements)
            else {
                dropped += 1
                continue
            }
            pointers.append(pointer)
        }
        if pointers.count > maxPointers {
            dropped += pointers.count - maxPointers
            pointers = Array(pointers.prefix(maxPointers))
        }

        var response = AssistantResponse(
            speech: speech.isEmpty ? fallbackSpeech : speech,
            pointers: pointers,
            code: code(in: object),
            language: (object["language"] ?? object["lang"]) as? String,
            action: action(in: object)
        )
        // Parts of a snipped thing: positions in the image, no element list involved.
        response.parts = (object["parts"].map(asArray) ?? []).compactMap { entry in
            (entry as? [String: Any]).flatMap { pointer(from: $0, imageWidth: imageWidth, imageHeight: imageHeight) }
        }.filter { !$0.label.isEmpty }
        if response.parts.isEmpty {
            response.parts = partsInText.filter { $0.x >= 0 && $0.y >= 0 && $0.x <= Double(imageWidth) && $0.y <= Double(imageHeight) }
        }
        return Result(
            response: response,
            usedFallback: speech.isEmpty,
            droppedPointers: dropped
        )
    }

    // MARK: - Code

    /// `"code": "…"`, or an array of lines. Empty means no code.
    static func code(in object: [String: Any]) -> String? {
        let raw = object["code"] ?? object["snippet"]
        let text: String? = switch raw {
        case let string as String: string
        case let lines as [String]: lines.joined(separator: "\n")
        default: nil
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text.trimmingCharacters(in: .newlines)
    }

    // MARK: - Action

    /// {"action": {"name": "move_to", "argument": "documents", "detail": null}}; numbers
    /// become strings ("argument": 30 for the volume).
    /// The action in a reply to `Prompt.orderSystem`, if any.
    public static func action(inReply raw: String) -> ActionRequest? {
        firstJSONObject(in: raw).flatMap(action(in:))
    }

    static func action(in object: [String: Any]) -> ActionRequest? {
        guard let dict = object["action"] as? [String: Any],
              let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty
        else { return nil }
        func text(_ value: Any?) -> String? {
            if let string = value as? String { return string.isEmpty ? nil : string }
            if let number = value as? NSNumber, !(value is Bool) { return number.stringValue }
            return nil
        }
        return ActionRequest(name: name, argument: text(dict["argument"]), detail: text(dict["detail"]))
    }

    // MARK: - Pointers

    static func pointer(from dict: [String: Any], imageWidth: Int, imageHeight: Int, elements: [PromptElement] = []) -> Pointer? {
        // {"element": 7}: exact position from the app's own accessibility data.
        if let id = number(dict["element"] ?? dict["element_id"] ?? dict["id"]),
           let element = elements.first(where: { Double($0.id) == id }) {
            let label = (dict["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Pointer(x: element.x, y: element.y, label: (label?.isEmpty ?? true) ? element.label : label!)
        }
        guard let (x, y) = coordinates(in: dict) else { return nil }
        let width = Double(imageWidth), height = Double(imageHeight)
        let slackX = width * edgeTolerance, slackY = height * edgeTolerance
        guard x.isFinite, y.isFinite,
              x >= -slackX, x <= width + slackX,
              y >= -slackY, y <= height + slackY,
              !(x < placeholderCorner && y < placeholderCorner)
        else { return nil }

        let label = (dict["label"] ?? dict["name"] ?? dict["text"]).flatMap { $0 as? String }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Coordinates for something that's in the list (models tend to copy them from it,
        // sometimes mixing up neighbours): use the listed element's exact center.
        if let match = listedElement(named: label, near: x, y, in: elements) {
            return Pointer(x: match.x, y: match.y, label: label)
        }
        return Pointer(x: min(max(x, 0), width - 1), y: min(max(y, 0), height - 1), label: label)
    }

    /// Listed elements whose name matches closely enough count; the nearest wins, up to
    /// `maxListedDistance` pixels away (so "OK" doesn't jump to another dialog's OK).
    static let maxListedDistance = 250.0

    private static func listedElement(named label: String, near x: Double, _ y: Double, in elements: [PromptElement]) -> PromptElement? {
        guard !label.isEmpty else { return nil }
        return elements
            .filter { LabelMatcher.similarity(label, $0.label) >= 0.8 }
            .map { ($0, ((($0.x - x) * ($0.x - x)) + (($0.y - y) * ($0.y - y))).squareRoot()) }
            .filter { $0.1 <= maxListedDistance }
            .min { $0.1 < $1.1 }?.0
    }

    private static func coordinates(in dict: [String: Any]) -> (Double, Double)? {
        // {"x": 10, "y": 20}
        if let x = number(dict["x"]), let y = number(dict["y"]) { return (x, y) }
        // {"x": [10, 20]} — seen from Qwen2.5-VL
        if let pair = numbers(dict["x"]), pair.count == 2 { return (pair[0], pair[1]) }
        for key in ["point", "point_2d", "coordinates", "position", "center"] {
            if let pair = numbers(dict[key]), pair.count == 2 { return (pair[0], pair[1]) }
        }
        for key in ["bbox_2d", "bbox", "box"] {
            if let box = numbers(dict[key]), box.count == 4 {
                return ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where !(number === kCFBooleanTrue || number === kCFBooleanFalse):
            number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespaces))
        default:
            nil
        }
    }

    private static func numbers(_ value: Any?) -> [Double]? {
        guard let array = value as? [Any] else { return nil }
        let values = array.compactMap(number)
        return values.count == array.count ? values : nil
    }

    private static func asArray(_ value: Any) -> [Any] {
        if let array = value as? [Any] { return array }
        if let single = value as? [String: Any] { return [single] }
        return []
    }

    // MARK: - JSON extraction

    /// The first balanced `{…}` that parses as a JSON object, ignoring fences and chatter.
    static func firstJSONObject(in text: String) -> [String: Any]? {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        while let open = scalars[start...].firstIndex(of: "{") {
            if let close = matchingBrace(in: scalars, from: open) {
                let candidate = String(String.UnicodeScalarView(scalars[open...close]))
                if let object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any] {
                    return object
                }
            }
            start = open + 1
        }
        return nil
    }

    private static func matchingBrace(in scalars: [Unicode.Scalar], from open: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in open..<scalars.count {
            let scalar = scalars[index]
            if inString {
                if escaped { escaped = false }
                else if scalar == "\\" { escaped = true }
                else if scalar == "\"" { inString = false }
                continue
            }
            switch scalar {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    /// Broken or missing JSON: use the speech the streaming extractor would have found,
    /// else the plain text if it doesn't look like JSON at all.
    static func salvageSpeech(from raw: String) -> String {
        var extractor = StreamingSpeechExtractor()
        let partial = extractor.feed(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty { return partial }

        let plain = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !plain.isEmpty, !plain.contains("{"), !plain.contains("}") { return plain }
        return fallbackSpeech
    }
}
