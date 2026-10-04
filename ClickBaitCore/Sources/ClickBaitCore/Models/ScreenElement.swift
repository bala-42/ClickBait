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

    /// The elements on the screenshot worth listing, numbered from 1, at most `limit`
    /// (every line costs the local model time). Elements whose names share words with
    /// the question come first, then open-menu items, then the rest in screen order.
    public static func list(_ elements: [ScreenElement], geometry: ScreenGeometry, question: String = "",
                            limit: Int = 50) -> [PromptElement] {
        let questionWords = Set(ImpliedPointer.normalized(question).split(separator: " ").filter { $0.count >= 3 })
        var seen = Set<String>()
        var ranked: [(element: ScreenElement, center: Point, tier: Int, overlap: Double, order: Int)] = []
        for (order, element) in elements.enumerated() {
            let center = geometry.imagePixel(fromQuartz: Point(x: element.frame.x + element.frame.width / 2,
                                                                y: element.frame.y + element.frame.height / 2))
            guard center.x >= 0, center.y >= 0, center.x < geometry.imageWidth, center.y < geometry.imageHeight else { continue }
            // The same name in the same spot twice (nested elements) is one thing.
            guard seen.insert("\(element.label)|\(Int(center.x / 4))|\(Int(center.y / 4))").inserted else { continue }
            let labelWords = ImpliedPointer.normalized(element.label).split(separator: " ").filter { $0.count >= 3 }
            let overlap = labelWords.isEmpty ? 0 : Double(labelWords.filter(questionWords.contains).count) / Double(labelWords.count)
            // Open menus and text boxes come right after name matches: "where do I type?"
            // names neither, and a message box low in the window was cut off by the limit.
            let textBox = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"].contains(element.role)
            let tier = overlap > 0 ? 0 : element.role == "AXMenuItem" || textBox ? 1 : 2
            ranked.append((element, center, tier, overlap, order))
        }
        let chosen = ranked
            .sorted { ($0.tier, -$0.overlap, $0.order) < ($1.tier, -$1.overlap, $1.order) }
            .prefix(limit)
            .sorted { $0.order < $1.order }  // back in screen order: easier to read
        return chosen.enumerated().map { index, item in
            PromptElement(id: index + 1, kind: item.element.kind, label: item.element.label,
                          x: item.center.x.rounded(), y: item.center.y.rounded())
        }
    }

    /// Whether `pointer` sits exactly on this element's listed center.
    public func isCenter(of pointer: Pointer) -> Bool {
        abs(pointer.x - x) < 0.5 && abs(pointer.y - y) < 0.5
    }

    /// One prompt line: `7: menu item "Show Path Bar" at (412, 300)`.
    var line: String { line(for: nil) }

    /// The line in the request's scale (0–1000 of the image for Qwen 3.5).
    func line(for request: AskRequest?) -> String {
        let name = label.replacingOccurrences(of: "\"", with: "'").split(whereSeparator: \.isNewline).joined(separator: " ")
        let short = name.count > 50 ? String(name.prefix(49)) + "…" : name
        var (px, py) = (x, y)
        if let request, request.coordinateScale == .thousandths, request.screenshotWidth > 0, request.screenshotHeight > 0 {
            px = x / Double(request.screenshotWidth) * 1000
            py = y / Double(request.screenshotHeight) * 1000
        }
        return "\(id): \(kind) \"\(short)\" at (\(Int(px)), \(Int(py)))"
    }
}
