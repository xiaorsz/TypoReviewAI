import Foundation
import NaturalLanguage
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum EnglishGlossSource: String {
    case ecdict = "ECDICT"
}

struct EnglishGloss: Equatable {
    let word: String
    let phonetic: String
    let translation: String
    let source: EnglishGlossSource

    var displayPhonetic: String {
        let trimmed = phonetic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("/") {
            return trimmed
        }
        return "[\(trimmed)]"
    }
}

final class EnglishGlossService {
    static let shared = EnglishGlossService()

    private let lock = NSLock()
    private var database: OpaquePointer?

    init(bundle: Bundle = .main) {
        guard let databaseURL = bundle.url(forResource: "EnglishDictionary", withExtension: "sqlite") else {
            return
        }

        if sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            sqlite3_close(database)
            database = nil
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func lookup(text: String) -> EnglishGloss? {
        let candidates = lookupCandidates(for: text)
        guard !candidates.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        for candidate in candidates {
            if let gloss = query(word: candidate) {
                return gloss
            }
        }

        return nil
    }

    private func query(word: String) -> EnglishGloss? {
        guard let database else { return nil }

        let sql = """
            SELECT word, phonetic, translation
            FROM entries
            WHERE word = ?
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, word, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let resolvedWord = columnText(statement, index: 0)
        let phonetic = columnText(statement, index: 1)
        let matchedWord = resolvedWord.isEmpty ? word : resolvedWord
        let translation = learningTranslationOverride(for: matchedWord)
            ?? normalizedTranslation(from: columnText(statement, index: 2))
        guard !translation.isEmpty else { return nil }

        return EnglishGloss(
            word: matchedWord,
            phonetic: phonetic,
            translation: translation,
            source: .ecdict
        )
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let rawValue = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func learningTranslationOverride(for word: String) -> String? {
        let overrides = [
            "hello": "你好；喂",
            "hi": "你好；嗨",
            "bye": "再见",
            "goodbye": "再见"
        ]
        return overrides[word.lowercased()]
    }

    private func normalizedTranslation(from rawTranslation: String) -> String {
        var glosses: [String] = []

        func appendGloss(_ value: String) {
            let normalized = value
                .replacingOccurrences(of: "（", with: "(")
                .replacingOccurrences(of: "）", with: ")")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            guard normalized.containsChineseCharacters else { return }
            guard !normalized.hasPrefix("[网络]") else { return }
            guard !normalized.hasPrefix("[例句]") else { return }
            guard !glosses.contains(normalized) else { return }
            glosses.append(normalized)
        }

        for line in rawTranslation.components(separatedBy: .newlines) {
            let withoutPartOfSpeech = line
                .replacingOccurrences(
                    of: #"^[a-zA-Z]+\.\s*"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let components = withoutPartOfSpeech
                .split(whereSeparator: { "；;、,，/".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if components.isEmpty {
                appendGloss(withoutPartOfSpeech)
            } else {
                components.forEach(appendGloss)
            }
        }

        return glosses.prefix(4).joined(separator: "；")
    }

    private func lookupCandidates(for text: String) -> [String] {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return [] }

        var candidates: [String] = []

        func appendCandidate(_ candidate: String?) {
            guard let candidate else { return }
            let normalized = candidate
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else { return }
            guard !candidates.contains(normalized) else { return }
            candidates.append(normalized)
        }

        appendCandidate(trimmed)

        if isLikelySingleEnglishWord(trimmed) {
            appendCandidate(englishLemma(for: trimmed))
            for candidate in englishBaseFormCandidates(for: trimmed) {
                appendCandidate(candidate)
            }
        }

        return candidates
    }

    private func isLikelySingleEnglishWord(_ text: String) -> Bool {
        let pattern = "^[A-Za-z]+(?:['-][A-Za-z]+)*$"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func englishLemma(for word: String) -> String? {
        let lowercased = word.lowercased()
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = lowercased
        let range = lowercased.startIndex..<lowercased.endIndex
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        var resolvedLemma: String?

        tagger.enumerateTags(in: range, unit: .word, scheme: .lemma, options: options) { tag, tokenRange in
            guard tokenRange == range, let rawValue = tag?.rawValue else { return true }
            resolvedLemma = rawValue
            return false
        }

        guard let rawValue = resolvedLemma else { return nil }
        let lemma = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lemma.isEmpty,
              lemma.caseInsensitiveCompare(lowercased) != ComparisonResult.orderedSame else { return nil }
        return lemma
    }

    private func englishBaseFormCandidates(for word: String) -> [String] {
        let lowercased = word.lowercased()
        guard lowercased.count >= 4 else { return [] }

        var candidates: [String] = []

        func appendCandidate(_ candidate: String?) {
            guard let candidate else { return }
            guard candidate.count >= 3 else { return }
            guard candidate.range(of: "^[a-z]+(?:['-][a-z]+)*$", options: .regularExpression) != nil else { return }
            guard !candidates.contains(candidate), candidate != lowercased else { return }
            candidates.append(candidate)
        }

        if lowercased.hasSuffix("ies"), lowercased.count > 4 {
            appendCandidate(String(lowercased.dropLast(3)) + "y")
        }

        if lowercased.hasSuffix("ves"), lowercased.count > 4 {
            let stem = String(lowercased.dropLast(3))
            appendCandidate(stem + "f")
            appendCandidate(stem + "fe")
        }

        if ["ses", "xes", "zes", "ches", "shes", "oes"].contains(where: { lowercased.hasSuffix($0) }) {
            appendCandidate(String(lowercased.dropLast(2)))
        } else if lowercased.hasSuffix("s"), !lowercased.hasSuffix("ss"), lowercased.count > 4 {
            appendCandidate(String(lowercased.dropLast()))
        }

        if lowercased.hasSuffix("ied"), lowercased.count > 4 {
            appendCandidate(String(lowercased.dropLast(3)) + "y")
        } else if lowercased.hasSuffix("ed"), lowercased.count > 4 {
            let stem = String(lowercased.dropLast(2))
            appendCandidate(stem)
            appendCandidate(stem + "e")
            if let dedoubled = droppingTrailingDoubleConsonant(from: stem) {
                appendCandidate(dedoubled)
            }
        }

        if lowercased.hasSuffix("ing"), lowercased.count > 5 {
            let stem = String(lowercased.dropLast(3))
            appendCandidate(stem)
            appendCandidate(stem + "e")
            if let dedoubled = droppingTrailingDoubleConsonant(from: stem) {
                appendCandidate(dedoubled)
            }
        }

        if lowercased.hasSuffix("er"), lowercased.count > 4 {
            let stem = String(lowercased.dropLast(2))
            appendCandidate(stem)
            appendCandidate(stem + "e")
            if let dedoubled = droppingTrailingDoubleConsonant(from: stem) {
                appendCandidate(dedoubled)
            }
        }

        if lowercased.hasSuffix("est"), lowercased.count > 5 {
            let stem = String(lowercased.dropLast(3))
            appendCandidate(stem)
            appendCandidate(stem + "e")
            if let dedoubled = droppingTrailingDoubleConsonant(from: stem) {
                appendCandidate(dedoubled)
            }
        }

        return Array(candidates.prefix(2))
    }

    private func droppingTrailingDoubleConsonant(from text: String) -> String? {
        guard text.count >= 4 else { return nil }
        let characters = Array(text)
        guard characters.count >= 2,
              characters[characters.count - 1] == characters[characters.count - 2],
              !"aeiou".contains(characters[characters.count - 1]) else {
            return nil
        }
        return String(characters.dropLast())
    }
}

private extension String {
    var containsChineseCharacters: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value)
        }
    }
}
