import Foundation

/// One spoken word: its text, start and end in seconds, and who said it once that's known.
struct MeetingWord: Sendable {
    var w: String
    var s: Double
    var e: Double
    var spk = ""
}

/// Two channels of words to one readable transcript. Mirrors scripts/meetings/m06.py (experiments M04, M06, M06b in
/// docs/MEETING-EXPERIMENTS.md), so what was measured there is what the app does.
enum MeetingTranscript {
    static let rate = 16_000.0

    /// Level of one word in dBFS over its span (M04). Very short words get at least 10 ms.
    static func level(_ audio: [Float], _ w: MeetingWord) -> Double {
        let start = min(Int(w.s * rate), audio.count)
        let end = min(max(Int(w.e * rate), start + 160), audio.count)
        guard end > start else { return 20 * log10(1e-9) }
        var sum = 0.0
        for x in audio[start..<end] { sum += Double(x) * Double(x) }
        return 20 * log10((sum / Double(end - start)).squareRoot() + 1e-9)
    }

    /// Your words, without what the mic only overheard from the speakers. A word stays if it is no more than 3 dB
    /// quieter on the mic than in the call audio (M04), and the call audio doesn't have the same word within 1 s (M06).
    static func keepMicWords(_ mic: [MeetingWord], call: [MeetingWord], micAudio: [Float], callAudio: [Float]) -> [MeetingWord] {
        var heard: [String: [Double]] = [:]
        for c in call { heard[letters(c.w), default: []].append(c.s) }
        return mic.filter { w in
            guard level(micAudio, w) - level(callAudio, w) >= -3 else { return false }
            return !(heard[letters(w.w)] ?? []).contains { abs($0 - w.s) < 1.0 }
        }
    }

    /// The speaker of each word: most overlap with a diarized segment, else the nearest segment. `segments` are
    /// (start, end, speaker), sorted by start.
    static func attribute(_ words: [MeetingWord], _ segments: [(Double, Double, String)]) -> [MeetingWord] {
        words.map { word in
            var best: String?
            var overlap = 0.0
            var hi = segments.partitioningIndex { $0.0 >= word.e }
            let lo = max(0, hi - 50)
            hi = max(hi, lo)
            for (s, e, spk) in segments[lo..<hi] {
                let o = min(e, word.e) - max(s, word.s)
                if o > overlap { best = spk; overlap = o }
            }
            if best == nil {
                let mid = (word.s + word.e) / 2
                best = segments.min { distance($0, mid) < distance($1, mid) }?.2
            }
            var w = word
            w.spk = best ?? "unknown"
            return w
        }
    }

    private static func distance(_ segment: (Double, Double, String), _ t: Double) -> Double {
        segment.0 <= t && t <= segment.1 ? 0 : min(abs(t - segment.0), abs(t - segment.1))
    }

    /// Names speakers in the order they first talk: Speaker `first`, the next number, and so on.
    static func label(_ words: [MeetingWord], from first: Int) -> [MeetingWord] {
        var order: [String: String] = [:]
        return words.sorted { $0.s < $1.s }.map { word in
            var w = word
            if order[w.spk] == nil { order[w.spk] = "Speaker \(order.count + first)" }
            w.spk = order[w.spk]!
            return w
        }
    }

    private static func letters(_ t: String) -> String {
        t.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Dictionary terms that sound like something said, closest first. Vocabulary.select, with two changes for
    /// meetings, where a wrong hint can put a name into the notes (M06b): a one-word term also matches two or three
    /// spoken words that spell it exactly ("murmur bee"), and a near match only counts if the spoken word isn't English.
    static func select(_ text: String, terms: [String], cap: Int = 12) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map { letters(String($0)) }.filter { !$0.isEmpty }
        func score(_ term: String) -> Double {
            let t = letters(term)
            guard t.count >= 3 else { return 0 }
            let n = term.split(whereSeparator: \.isWhitespace).count
            var best = 0.0
            for i in 0..<max(words.count - n + 1, 0) {
                let w = words[i..<(i + n)].joined()
                if w == t { return 1 }
                if w.first == t.first, !PostEdit.english.contains(w) {
                    let s = Vocabulary.similarity(w, t)
                    if s >= 0.6 { best = max(best, s) }
                }
            }
            for k in [n + 1, n + 2] where words.count >= k {
                for i in 0...(words.count - k) where words[i..<(i + k)].joined() == t { return 1 }
            }
            return best
        }
        let scored = terms.map { (score($0), $0) }.filter { $0.0 > 0 }
        return Array(scored.enumerated().sorted { ($0.element.0, $1.offset) > ($1.element.0, $0.offset) }
            .map(\.element.1).prefix(cap))
    }

    /// Joins words that spell a term ("murmur bee" to "Murmurbee"), then PostEdit.snapNames: a capitalised word that
    /// isn't English and is at least 0.75 similar to a term becomes that term.
    static func snap(_ words: [MeetingWord], terms: [String]) -> [MeetingWord] {
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var exact: [String: String] = [:]
        for t in terms where !t.contains(" ") && letters(t).count >= 5 { exact[letters(t)] = t }
        let names = terms.filter { $0.first?.isUppercase == true && !$0.contains(" ") && $0.count >= 3 }
        var out: [MeetingWord] = []
        var i = 0
        next: while i < words.count {
            for k in [3, 2] where i + k <= words.count {
                let run = words[i..<(i + k)]
                if Set(run.map(\.spk)).count == 1, let term = exact[run.map { letters($0.w) }.joined()] {
                    let last = run.last!
                    let tail = String(last.w.reversed().prefix { !isWord($0) }.reversed())
                    var joined = words[i]
                    joined.w = term + tail
                    joined.e = last.e
                    out.append(joined)
                    i += k
                    continue next
                }
            }
            var w = words[i]
            let core = w.w.filter(isWord)
            if core.count >= 3, core.first?.isUppercase == true, !PostEdit.english.contains(core.lowercased()),
               !names.contains(core), !names.isEmpty {
                let lower = core.lowercased()
                let similar = { (t: String) in Vocabulary.similarity(lower, t.lowercased()) }
                if let best = names.max(by: { similar($0) < similar($1) }), similar(best) >= 0.75,
                   best.first?.lowercased() == core.first?.lowercased() {
                    w.w = w.w.replacingOccurrences(of: core, with: best)
                }
            }
            out.append(w)
            i += 1
        }
        return out
    }

    /// One line per turn, "[mm:ss] Speaker: text". A turn ends when the speaker changes or pauses for over a second;
    /// a one- or two-word line wedged inside someone else's turn is folded away so the turn reads whole (M06b).
    static func turns(_ words: [MeetingWord]) -> String {
        struct Line { var spk: String; var s: Double; var e: Double; var text: [String] }
        var lines: [Line] = []
        for w in words.sorted(by: { $0.s < $1.s }) {
            if let last = lines.last, last.spk == w.spk, w.s - last.e <= 1.0 {
                lines[lines.count - 1].text.append(w.w)
                lines[lines.count - 1].e = w.e
            } else {
                lines.append(Line(spk: w.spk, s: w.s, e: w.e, text: [w.w]))
            }
        }
        var i = 1
        while i < lines.count - 1 {
            let (a, b, c) = (lines[i - 1], lines[i], lines[i + 1])
            if b.text.count <= 2, a.spk == c.spk, c.spk != b.spk, c.s - a.e <= 2.0 {
                lines[i - 1].text += c.text
                lines[i - 1].e = c.e
                lines.removeSubrange(i...(i + 1))
            } else {
                i += 1
            }
        }
        return lines.map { l in
            String(format: "[%02d:%02d] %@: %@", Int(l.s / 60), Int(l.s) % 60, l.spk, l.text.joined(separator: " "))
        }.joined(separator: "\n")
    }
}

/// The prompt behind the notes. M06b's, plus two lines from M11 (whether attempts worked, no secrets), plus the notes
/// you typed during the call, which steer what gets covered
/// but aren't treated as facts: M10 found the model turning a typed line nobody said into a decision. What you typed
/// is shown word for word by `Meeting.fullNotes` instead.
enum MeetingPrompt {
    /// `you` is the name on your own lines, or nil when everyone was in the room and nobody's voice is known.
    static func notes(you: String?, vocab: [String], typed: String, transcript: String) -> String {
        let intro = you.map {
            "Below is the transcript of a call that \($0) recorded. \($0)'s lines are labelled \($0); everyone else is "
                + "labelled Speaker 2, Speaker 3, and so on."
        } ?? "Below is the transcript of a meeting. Speakers are labelled Speaker 1, Speaker 2, and so on."
        let hint = vocab.isEmpty ? "" : "\nThese names and words may come up; this is how they are spelled (speech "
            + "recognition may have misheard them as something that sounds similar): \(vocab.joined(separator: ", ")).\n"
        let writer = you ?? "The person taking notes"
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = trimmed.isEmpty ? "" : """


            \(writer) typed the notes below during the call, to mark what mattered. Give those topics extra attention: \
            find them in the transcript and write what was said about them. Use the typed notes only to decide what to \
            cover. Do not repeat them, and do not state anything from them that the transcript doesn't support.

            Typed notes:
            \(trimmed)
            """
        return """
            \(intro) Each line starts with the time it was said. The transcript comes from speech recognition, so \
            expect misheard words and broken sentences; read for what people meant.
            \(hint)
            Write notes on the call in Markdown:

            ## Summary
            Two to four sentences: what the call was about and what happened, in order.

            ## Notes
            Bullet points in the order things came up. Say who said or did each thing. Keep the specific details \
            people gave: names, places, times, numbers and plans.

            ## Action items
            Bullet points: who will do what next. Leave this section out if nobody said they would do anything.

            ## Decisions
            Bullet points: what was agreed. Leave this section out if nothing was agreed.

            Only include what the transcript supports. Keep track of who said what: when someone asks a question or \
            calls another person something, that is not a description of themselves. When someone tries to do \
            something, say whether it worked, failed or was left for later; don't assume it worked. Do not guess \
            names, dates or numbers that were not said, and never write down passwords, sign-in codes or other secrets.\(own)

            Transcript:
            \(transcript)
            """
    }
}

extension Array {
    /// The first index whose element satisfies `belongs`, given every element before it doesn't.
    func partitioningIndex(where belongs: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if belongs(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
