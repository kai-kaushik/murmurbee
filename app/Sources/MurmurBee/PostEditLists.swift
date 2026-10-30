import Foundation

/// Spoken lists ("first pick a date, second pick a restaurant, and third…") become numbered lists. This runs once on
/// the final text, after the chunks are joined: a chunk is cleaned before the model knows a list is coming, so the
/// model alone only ever numbers the later items (or none, with a personal model trained on prose).
extension PostEdit {
    private enum MarkerKind { case ordinal, numberWord, digit }
    private struct Marker { let value: Int; let kind: MarkerKind; let range: Range<String.Index>; let boundary: Bool }

    private static let markerValues: [String: Int] = [
        "first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3, "fourth": 4, "fourthly": 4,
        "fifth": 5, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    ]
    private static let markerPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(firstly|first|secondly|second|thirdly|third|fourthly|fourth|fifth|one|two|three|four|five|[1-9])\b(\.(?!\d)|,|:|\))?"#)

    static func formatSpokenList(_ text: String) -> String {
        let markers = findMarkers(text)
        guard let run = longestRun(markers, in: text), run.count >= 2 else { return text }
        // A mid-sentence start ("plan a team dinner first pick…") needs the whole sequence to vouch for it, or
        // "the first and second picture" would turn into a list.
        if !run[0].boundary && run.count < 3 { return text }
        // Already a written list (every item starts its own line): leave it alone.
        if run.allSatisfy({ $0.kind == .digit && (text[..<$0.range.lowerBound].last ?? "\n") == "\n" }) { return text }

        var items: [String] = []
        for (i, m) in run.enumerated() {
            let end = i + 1 < run.count ? run[i + 1].range.lowerBound : text.endIndex
            items.append(String(text[m.range.upperBound..<end]))
        }
        // The last item ends at its first sentence end; anything after it ("Thanks.") is its own paragraph.
        var rest = ""
        if let last = items.last, let stop = last.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            rest = String(last[stop.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            items[items.count - 1] = String(last[..<stop.lowerBound])
        }
        // Items are short instructions: every one but the last fits in one sentence, and each has a few words.
        // Long spoken paragraphs ("Firstly, … . Secondly, …") stay prose.
        // Checked after cleanItem, so the "And" of "…restaurant. And thirdly…" doesn't count as a second sentence.
        for item in items.dropLast() where cleanItem(item)
            .dropLast().range(of: #"[.!?](\s|$)"#, options: .regularExpression) != nil { return text }
        let cleaned = items.map(cleanItem)
        guard cleaned.allSatisfy({ $0.split(separator: " ").count >= 2 && $0.split(separator: " ").count <= 25 }) else { return text }

        var intro = String(text[..<run[0].range.lowerBound])
        while let c = intro.last, c == " " || c == "\t" { intro.removeLast() }
        intro = intro.trimmingCharacters(in: .newlines)
        if let c = intro.last, c.isLetter || c.isNumber { intro += ":" }
        else if intro.hasSuffix(",") { intro = String(intro.dropLast()) + ":" }

        let list = cleaned.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return (intro.isEmpty ? "" : intro + "\n") + list + (rest.isEmpty ? "" : "\n\n" + rest)
    }

    private static func findMarkers(_ text: String) -> [Marker] {
        let ns = NSRange(text.startIndex..., in: text)
        return markerPattern.matches(in: text, range: ns).compactMap { m in
            guard let r = Range(m.range, in: text), let wr = Range(m.range(at: 1), in: text) else { return nil }
            let word = text[wr].lowercased()
            let value = Int(word) ?? markerValues[word] ?? 0
            let kind: MarkerKind = Int(word) != nil ? .digit : (markerValues[word]! >= 1 && ["one", "two", "three", "four", "five"].contains(word) ? .numberWord : .ordinal)
            let punct = m.range(at: 2).location != NSNotFound
            let next = text[r.upperBound...].first { !$0.isWhitespace }
            let boundary = atBoundary(text, r.lowerBound)
            // Number words and digits need clear list shape, or "one of the things" and "1 dollar" would match.
            switch kind {
            case .digit: guard boundary, punct, text[wr.upperBound...].first == "." || text[wr.upperBound...].first == ")" else { return nil }
            case .numberWord: guard boundary, punct || next?.isUppercase == true else { return nil }
            case .ordinal: break
            }
            guard next?.isLetter == true else { return nil }
            return Marker(value: value, kind: kind, range: r, boundary: boundary)
        }
    }

    /// Start of text, after punctuation or a line break, or after a joining word ("and third…").
    private static func atBoundary(_ text: String, _ i: String.Index) -> Bool {
        let before = text[..<i]
        let trimmed = before.reversed().drop { $0 == " " || $0 == "\t" }
        guard let c = trimmed.first else { return true }
        if ".,;:!?\n".contains(c) { return true }
        let word = String(trimmed.prefix { $0.isLetter }.reversed()).lowercased()
        return ["and", "then", "next", "also"].contains(word)
    }

    /// 1, 2, 3… in order. Every marker after the first needs a boundary; the first may sit mid-sentence
    /// ("plan a team dinner first pick a date") because the rest of the sequence vouches for it.
    private static func longestRun(_ markers: [Marker], in text: String) -> [Marker]? {
        var best: [Marker] = []
        for (i, start) in markers.enumerated() where start.value == 1 && (start.boundary || start.kind == .ordinal) {
            var run = [start]
            for m in markers[(i + 1)...] where m.value == run.last!.value + 1 && m.boundary { run.append(m) }
            if run.count > best.count { best = run }
        }
        return best.isEmpty ? nil : best
    }

    private static func cleanItem(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        while true {
            let before = s
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:."))
            for tail in [" and", " then", " also"] where s.lowercased().hasSuffix(tail) { s = String(s.dropLast(tail.count)) }
            if s == before { break }
        }
        guard let f = s.first else { return "" }
        s = f.uppercased() + s.dropFirst()
        if let l = s.last, !"!?".contains(l) { s += "." }
        return s
    }
}
