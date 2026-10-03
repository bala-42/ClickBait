/// Something clickable that Accessibility reported on screen, offered to the model as a
/// numbered choice so it can point by id instead of guessing pixel coordinates.
public struct ScreenElement: Equatable, Sendable {
    /// Accessibility role, e.g. `AXMenuItem`.
    public var role: String
    public var label: String
    /// Global Quartz points.
    public var frame: Rect

    public init(role: String, label: String, frame: Rect) {
        self.role = role
        self.label = label
        self.frame = frame
    }

    /// A plain word for the prompt: `AXMenuItem` → "menu item".
    public var kind: String {
        switch role {
        case "AXButton", "AXMenuButton": "button"
        case "AXMenuItem": "menu item"
        case "AXMenuBarItem": "menu"
        case "AXPopUpButton": "pop-up menu"
        case "AXCheckBox": "checkbox"
        case "AXRadioButton": "radio button"
        case "AXTextField", "AXSearchField", "AXComboBox": "text field"
        case "AXTextArea": "text area"
        case "AXRow": "row"
        case "AXTab": "tab"
        case "AXLink": "link"
        case "AXDisclosureTriangle": "disclosure triangle"
        case "AXDockItem": "Dock item"
        default: role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role
        }
    }
}

/// A `ScreenElement` as listed in the prompt: numbered, with its center in screenshot pixels.
public struct PromptElement: Equatable, Sendable {
    public var id: Int
    public var kind: String
    public var label: String
    /// Center in screenshot pixels (the space the model's coordinates use).
    public var x: Double
    public var y: Double

    public init(id: Int, kind: String, label: String, x: Double, y: Double) {
        self.id = id
        self.kind = kind
        self.label = label
        self.x = x
        self.y = y
    }

    /// Numbers the elements that are on the screenshot, in order, from 1.
    public static func list(_ elements: [ScreenElement], geometry: ScreenGeometry, limit: Int = 120) -> [PromptElement] {
        var result: [PromptElement] = []
        for element in elements {
            let center = geometry.imagePixel(fromQuartz: Point(x: element.frame.x + element.frame.width / 2,
                                                                y: element.frame.y + element.frame.height / 2))
            guard center.x >= 0, center.y >= 0, center.x < geometry.imageWidth, center.y < geometry.imageHeight else { continue }
            result.append(PromptElement(id: result.count + 1, kind: element.kind, label: element.label,
                                        x: center.x.rounded(), y: center.y.rounded()))
            if result.count == limit { break }
        }
        return result
    }

    /// One prompt line: `7: menu item "Show Path Bar" at (412, 300)`.
    var line: String {
        let name = label.replacingOccurrences(of: "\"", with: "'").split(whereSeparator: \.isNewline).joined(separator: " ")
        let short = name.count > 50 ? String(name.prefix(49)) + "…" : name
        return "\(id): \(kind) \"\(short)\" at (\(Int(x)), \(Int(y)))"
    }
}
