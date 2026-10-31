import Foundation
import NaturalLanguage

/// Uses Apple's on-device language recognizer to keep ordinary answers in the language
/// the user is speaking. Very short or uncertain text gets no hint so names and brief
/// phrases are not misclassified.
enum ReplyLanguage {
    static func instruction(for text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard text.count >= 18, words.count >= 4 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 3)
            .max(by: { $0.value < $1.value }), confidence >= 0.75,
              let name = Locale(identifier: "en").localizedString(forIdentifier: language.rawValue) else {
            return nil
        }
        return "The user's message is in \(name). Reply in \(name) unless they ask for another language."
    }
}
