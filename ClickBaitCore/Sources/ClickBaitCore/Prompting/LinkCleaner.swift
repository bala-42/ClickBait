import Foundation

/// A copied link without its tracking (user's choice, 2026-11-02, after Vorssaint's Clean URL):
/// utm_… and the click ids ad networks and social apps add. Only when the whole copy is one
/// web link; the rest of the link stays exactly as it was.
public enum LinkCleaner {
    static let tracking: Set<String> = ["fbclid", "gclid", "gclsrc", "dclid", "msclkid", "mc_eid", "mc_cid", "igshid", "igsh",
                                        "si", "yclid", "twclid", "ttclid", "_hsenc", "_hsmi", "mkt_tok", "ref_src", "s_cid", "spm"]

    /// The cleaned link, or nil when there was nothing to take off (or it isn't a link).
    public static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let items = parts.queryItems, !items.isEmpty else { return nil }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !tracking.contains(name)
        }
        guard kept.count < items.count else { return nil }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.string
    }
}
