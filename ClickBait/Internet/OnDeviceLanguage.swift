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

    /// Picks the passages closest to the question by meaning with nomic (ClickBait's standard
    /// embedding model): measured 2026-11-01 on 8 questions, nomic picked the answering
    /// passage 5 times, Apple's sentence model 2. Apple's stands in when nomic isn't there.
    static func pickPassagesByMeaning(_ documents: [WebDocument], question: String) async -> [WebPassage] {
        let chunks = Array(Set(documents.flatMap { PassagePicker.chunks(of: $0.text) }))
        guard !chunks.isEmpty,
              let query = await Embedder.vectors([question], as: .query, within: 2)?.first,
              let vectors = await Embedder.vectors(chunks, as: .document, within: 3) else {
            return pickPassages(documents, question: question)
        }
        var similarity: [String: Double] = [:]
        for (chunk, vector) in zip(chunks, vectors) { similarity[chunk] = Double(SmartSearch.cosine(query, vector)) }
        return PassagePicker.pick(documents, question: question) { question, passage in
            // nomic's band (unrelated ≈ 0.45, a match ≈ 0.6–0.75) spread over 0…1.
            min(1, max(0, ((similarity[passage] ?? 0.5) - 0.5) / 0.25)) + 0.3 * PassagePicker.wordOverlap(question, passage)
        }
    }

    /// Apple's on-device sentence model, falling back to shared words when it isn't available.
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
