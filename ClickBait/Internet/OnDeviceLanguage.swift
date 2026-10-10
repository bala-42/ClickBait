import ClickBaitCore
import NaturalLanguage

/// Apple's on-device language tools for Internet Mode: nothing here goes online.
enum OnDeviceLanguage {
    /// People's names in some text (the screen's words), to keep them out of a search.
    static func personalNames(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName { names.append(String(text[range])) }
            return true
        }
        return names
    }

    /// Picks the passages closest to the question by meaning (sentence embeddings), falling
    /// back to shared words when the embedding isn't available.
    static func pickPassages(_ documents: [WebDocument], question: String) -> [WebPassage] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return PassagePicker.pick(documents, question: question)
        }
        return PassagePicker.pick(documents, question: question) { question, passage in
            // Cosine distance is 0 (same) … 2 (opposite); embeddings read the first few
            // hundred characters well, so long passages are scored by their opening.
            let distance = embedding.distance(between: question, and: String(passage.prefix(400)), distanceType: .cosine)
            return max(0, 2 - distance) / 2 + 0.3 * PassagePicker.wordOverlap(question, passage)
        }
    }
}
