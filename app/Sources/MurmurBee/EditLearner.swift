import AppKit

/// Learns from what the user changes after a paste: finds the inserted span in the field's later contents,
/// diffs it word by word, and turns name corrections ("Priyanca" → "Priyanka") into dictionary entries.
/// Swift port of scripts/learn.py, run live so corrections take effect on the next dictation.
enum EditLearner {
    /// The inserted text as it reads now, located by the unchanged text around it right after pasting.
    static func editedSpan(inserted: String, after: String, later: String) -> String? {
        guard let r = after.range(of: inserted) else { return nil }
        let prefix = String(after[..<r.lowerBound].suffix(40))
        let suffix = String(after[r.upperBound...].prefix(40))
        var start = later.startIndex
        if !prefix.isEmpty {
            guard let p = later.range(of: prefix) else { return nil }
            start = p.upperBound
        }
        var end = later.endIndex
        if !suffix.isEmpty {
            guard let s = later.range(of: suffix, range: start..<later.endIndex) else { return nil }
            end = s.lowerBound
        }
        let span = String(later[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return resembles(inserted, span) ? span : nil
    }

    /// An edit keeps most of the dictated words. Without this, a chat box that's emptied by sending (where the
    /// dictation was the whole field, so there's no surrounding text to anchor on) reads as "edited to nothing".
    static func resembles(_ inserted: String, _ span: String) -> Bool {
        let x = inserted.split(whereSeparator: \.isWhitespace), y = span.split(whereSeparator: \.isWhitespace)
        guard !x.isEmpty, !y.isEmpty, x.count < 400, y.count < 400 else { return false }
        var dp = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                dp[i][j] = x[i] == y[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        let kept = Double(dp[0][0])
        if x.count <= 3 { return kept >= Double(x.count - 1) && y.count <= x.count + 2 }
        return kept / Double(x.count) >= 0.5 && kept / Double(y.count) >= 0.5
    }

    /// Word-level replacements of one or two words, via a small LCS alignment.
    static func replacements(_ a: String, _ b: String) -> [(String, String)] {
        let x = a.split(whereSeparator: \.isWhitespace).map(String.init)
        let y = b.split(whereSeparator: \.isWhitespace).map(String.init)
        guard x.count < 400, y.count < 400 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                dp[i][j] = x[i] == y[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [(String, String)] = []
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] { i += 1; j += 1; continue }
            let (si, sj) = (i, j)
            while i < x.count || j < y.count {
                if i < x.count, j < y.count, x[i] == y[j] { break }
                if j < y.count, i == x.count || dp[i][j + 1] >= dp[i + 1][j] { j += 1 } else { i += 1 }
            }
            if i - si >= 1, i - si <= 2, j - sj >= 1, j - sj <= 2 {
                out.append((x[si..<i].joined(separator: " "), y[sj..<j].joined(separator: " ")))
            }
        }
        return out
    }

    /// Terms worth remembering: the replacement differs from the original, sounds alike, and is a name or other
    /// unusual word (capitalised, or not in the system dictionary, like "kubectl"). Ordinary words are skipped so
    /// grammar fixes ("their" → "there") don't fill the dictionary.
    @MainActor
    static func learnedTerms(inserted: String, edited: String, known: Set<String>) -> [String] {
        let strip = CharacterSet.punctuationCharacters.union(.whitespaces)
        var terms: [String] = []
        for (old, new) in replacements(inserted, edited) {
            let o = old.trimmingCharacters(in: strip), n = new.trimmingCharacters(in: strip)
            guard let first = n.first, first.isUppercase || unusual(n), n.count >= 3, o.lowercased() != n.lowercased(),
                  !known.contains(n), !terms.contains(n),
                  Vocabulary.similarity(o.lowercased(), n.lowercased()) >= 0.5 else { continue }
            terms.append(n)
        }
        return terms
    }

    @MainActor
    static func unusual(_ word: String) -> Bool {
        if word.contains(where: { $0.isNumber || $0.isUppercase }) { return true }
        return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en",
                                                   wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
    }

    /// Append auto-learned terms to the dictionary file, tagged so the Dictionary tab can show them.
    static func addToDictionary(_ terms: [String]) {
        guard !terms.isEmpty else { return }
        let existing = (try? String(contentsOf: Vocabulary.file, encoding: .utf8)) ?? ""
        let text = existing + (existing.hasSuffix("\n") || existing.isEmpty ? "" : "\n")
            + terms.map { "\($0)  # auto" }.joined(separator: "\n") + "\n"
        try? text.write(to: Vocabulary.file, atomically: true, encoding: .utf8)
    }
}
