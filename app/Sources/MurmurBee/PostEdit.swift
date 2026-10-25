import AppKit

/// Small deterministic touch-ups applied to the model's output, each fixing a failure seen in real use (E13).
enum PostEdit {
    /// The user's own name, always offered as vocabulary, and used for sign-offs.
    /// From Settings ("Name you sign with"), falling back to the macOS account name.
    static var userNames: [String] {
        let set = UserDefaults.standard.string(forKey: "signName")?.trimmingCharacters(in: .whitespaces) ?? ""
        let full = set.isEmpty ? NSFullUserName().trimmingCharacters(in: .whitespaces) : set
        guard !full.isEmpty else { return [] }
        let first = full.split(separator: " ").first.map(String.init) ?? full
        return first == full ? [full] : [full, first]
    }

    /// English words (macOS's /usr/share/dict/words, ~235k), lowercased. Thread-safe, loaded once.
    static let english: Set<String> = {
        let text = (try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    /// "Samm" → "Sam" when Sam is in the hints: replace a capitalised word that isn't an English word with
    /// the hint it closely resembles. Real words and dissimilar names ("Vikram") are left alone.
    static func snapNames(_ text: String, vocab: [String]) -> String {
        let names = vocab.filter { $0.first?.isUppercase == true && !$0.contains(" ") && $0.count >= 3 }
        guard !names.isEmpty else { return text }
        var out = ""
        var word = ""
        func flush() {
            defer { word = "" }
            guard word.count >= 3, word.first?.isUppercase == true, !names.contains(word) else { out += word; return }
            let lower = word.lowercased()
            let misspelled = !english.contains(lower)
            guard misspelled,
                  let best = names.max(by: { Vocabulary.similarity(lower, $0.lowercased()) < Vocabulary.similarity(lower, $1.lowercased()) }),
                  Vocabulary.similarity(lower, best.lowercased()) >= 0.75, best.first?.lowercased() == lower.first.map(String.init)
            else { out += word; return }
            out += best
        }
        for ch in text {
            if ch.isLetter { word.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    /// Speech recognition ends every chunk with a full stop. When the next chunk carries on the sentence (starts
    /// lowercase), that full stop is false: drop it. Abbreviations like "Mr." and "a.m." keep theirs.
    static func dropFalseStop(_ written: String, before piece: String) -> String {
        guard written.hasSuffix("."), let first = piece.first, first.isLowercase else { return written }
        let lastWord = written.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "a.m.", "p.m.", "etc.", "e.g.", "i.e.", "vs.", "st."]
        if abbreviations.contains(lastWord.lowercased()) || lastWord.filter({ $0 == "." }).count > 1 { return written }
        return String(written.dropLast())
    }

    /// In email: a sign-off followed by a short misheard word ("Regards. Hi.", "regard Sky") is the user's name.
    static func fixSignoff(_ text: String, appType: String) -> String {
        guard appType == "email", let first = userNames.last else { return text }
        let pattern = #"(?i)(?:^|\n|\s)(regards?|best regards|kind regards|best|thanks|many thanks|cheers|sincerely)(?:[,.]\s*|\s+)\n?\s*([A-Za-z]{1,4})\.?\s*$"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return text }
        let tail = String(text[r])
        let parts = tail.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        guard let name = parts.last, name.lowercased() != first.lowercased() else { return text }
        var phrase = parts.dropLast().joined(separator: " ").lowercased()
        if phrase == "regard" { phrase = "regards" }
        let signoff = phrase.prefix(1).uppercased() + phrase.dropFirst()
        let head = text[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return head + "\n\n" + signoff + ",\n" + first
    }

    static let correctionCue = #"(?i)\b(no wait|wait no|sorry|i mean|actually|correct that|scratch that|or rather|make that|no no)\b"#
}
