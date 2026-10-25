import FluidAudio
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Parakeet Ultra on the Neural Engine. One actor = one transcription at a time.
actor Transcriber {
    static let origin = "parakeet-tdt-ultra@fluidaudio"
    private var asr: AsrManager?

    func load() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .ultra)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
        _ = try await transcribe([Float](repeating: 0, count: 16_000))  // warm the ANE
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let asr else { return "" }
        guard samples.count > 16_000 / 4 else { return "" }  // < 0.25 s: nothing to hear
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(samples, decoderState: &state).text
    }
}

/// Everything the app knows when you dictate, beyond the transcript (prompt v3).
struct PromptContext: Sendable {
    var user = "", locale = "", tz = "", time = "", url = "", selected = "", after = ""
}

/// Prompt format v3 (E13+). Mirrors scripts/prompt_v3.py exactly; the model is trained on it.
enum PromptV3 {
    static func userMessage(appName: String, appType: String, raw: String, vocab: [String], before: String,
                            ctx: PromptContext) -> String {
        var lines = ["app=\(appName) type=\(appType)"]
        if !ctx.user.isEmpty { lines.append("user=\(ctx.user)") }
        let when = [ctx.locale.isEmpty ? "" : "locale=\(ctx.locale)", ctx.tz.isEmpty ? "" : "tz=\(ctx.tz)",
                    ctx.time.isEmpty ? "" : "time=\(ctx.time)"].filter { !$0.isEmpty }.joined(separator: " ")
        if !when.isEmpty { lines.append(when) }
        if !ctx.url.isEmpty { lines.append("url=\(ctx.url)") }
        if !vocab.isEmpty { lines.append("vocab: " + vocab.prefix(PromptV2.maxVocab).joined(separator: "; ")) }
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let blocks = [("selected", trim(String(ctx.selected.prefix(300)))), ("before", trim(String(before.suffix(200)))),
                      ("after", trim(String(ctx.after.prefix(120))))]
        for (tag, text) in blocks where !text.isEmpty { lines.append("<\(tag)>\(text)</\(tag)>") }
        lines.append("<transcript>\(trim(raw))</transcript>")
        return lines.joined(separator: "\n")
    }
}

/// Prompt format v2. Mirrors scripts/prompt_v2.py exactly; the model was trained on it.
enum PromptV2 {
    static let beforeChars = 200
    static let maxVocab = 12

    static func userMessage(appName: String, appType: String, raw: String, vocab: [String], before: String) -> String {
        var lines = ["app=\(appName) type=\(appType)"]
        if !vocab.isEmpty { lines.append("vocab: " + vocab.prefix(maxVocab).joined(separator: "; ")) }
        let b = String(before.suffix(beforeChars)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty { lines.append("<before>\(b)</before>") }
        lines.append("<transcript>\(raw.trimmingCharacters(in: .whitespacesAndNewlines))</transcript>")
        return lines.joined(separator: "\n")
    }

    /// How a cleaned chunk is appended to what's already been written this dictation.
    static func join(_ written: String, _ piece: String, appType: String) -> String {
        let piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty else { return piece }
        guard !piece.isEmpty else { return written }
        let lastLine = written.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").last ?? ""
        let sep: String
        if isListItem(piece) {
            sep = written.hasSuffix("\n") ? "" : "\n"
        } else if appType == "email" && isSignoff(piece) {
            sep = "\n\n"
        } else if isListItem(lastLine), piece.first?.isUppercase == true {
            sep = "\n\n"
        } else {
            sep = " "
        }
        var w = written
        while w.hasSuffix(" ") { w.removeLast() }
        let p = isListItem(lastLine) && isListItem(piece) ? continueList(w, piece) : piece
        guard !p.isEmpty else { return w }
        return w + sep + p
    }

    /// A chunk that continues a numbered list sometimes repeats the last item ("2. Implementation" again) or
    /// restarts the numbering. Drop items already written and renumber the rest after the last one.
    static func continueList(_ written: String, _ piece: String) -> String {
        let item = #"^(\d+)\.\s+(.*)$"#
        func parse(_ line: String) -> (Int, String)? {
            guard let r = line.range(of: item, options: .regularExpression) else { return nil }
            let l = String(line[r])
            let num = Int(l.prefix { $0.isNumber }) ?? 0
            let text = l.drop { $0.isNumber || $0 == "." || $0 == " " }
            return (num, String(text))
        }
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let previous = written.components(separatedBy: "\n").reversed().prefix { parse($0) != nil }
        var seen = Set(previous.compactMap { parse($0).map { key($0.1) } })
        var next = (previous.first.flatMap(parse)?.0 ?? 0) + 1
        var out: [String] = []
        for line in piece.components(separatedBy: "\n") {
            if let (_, text) = parse(line) {
                let k = key(text)
                if seen.contains(k) { continue }
                seen.insert(k)
                out.append("\(next). \(text)")
                next += 1
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isListItem(_ s: String) -> Bool {
        s.range(of: #"^(\d+\.|[-•]) "#, options: .regularExpression) != nil
    }

    static func isSignoff(_ s: String) -> Bool {
        (s + "\n").range(of: #"^(Regards|Best regards|Kind regards|Warm regards|Best|Thanks|Many thanks|Thank you|Cheers)\b[,!]?\s*\n"#,
                          options: .regularExpression) != nil
    }
}

/// The fine-tuned cleanup model (Qwen3.5-0.8B + a LoRA, fused), prompted exactly as it was trained.
/// A model directory containing localflow.json {"prompt": "v2"} gets prompt v2 (vocab + before-context).
actor Cleaner {
    static let system = "Clean up this dictated transcript. Output only the cleaned text."
    private var container: ModelContainer?
    private(set) var promptVersion = "v1"
    private(set) var origin = ""

    enum Path: String { case skip, model, fallbackRules = "fallback_rules", off }

    func load(from dir: URL) async throws {
        container = try await loadModelContainer(from: dir, using: #huggingFaceTokenizerLoader())
        if let data = try? Data(contentsOf: dir.appendingPathComponent("localflow.json")),
           let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = cfg["prompt"] as? String { promptVersion = v }
        origin = dir.lastPathComponent
        _ = await clean("warm up the model please", appName: "Notes", appType: "general")
    }

    func clean(_ raw: String, appName: String, appType: String,
               vocab: [String] = [], before: String = "", ctx: PromptContext = PromptContext(),
               allowTailRepair: Bool = true) async -> (String, Path) {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = raw.split(separator: " ")
        guard let container, !raw.isEmpty else { return (raw, .skip) }
        let v2 = promptVersion == "v2" || promptVersion == "v3"
        // Short and plain: Parakeet's punctuation is good enough, skip the model. With v2, short pieces can
        // still need structure (a sign-off, the next list item), so only skip with no context at all.
        let canSkip = v2 ? (before.isEmpty && appType != "email") : !Self.hasFiller(raw)
        if words.count <= 3 && canSkip { return (raw, .skip) }

        let prompt = promptVersion == "v3"
            ? PromptV3.userMessage(appName: appName, appType: appType, raw: raw, vocab: vocab, before: before, ctx: ctx)
            : v2
            ? PromptV2.userMessage(appName: appName, appType: appType, raw: raw, vocab: vocab, before: before)
            : "app=\(appName) type=\(appType)\n<transcript>\(raw)</transcript>"
        let maxTokens = Int(Double(words.count) * 1.3 * 1.6) + 24
        do {
            let input = try await container.prepare(input: UserInput(
                chat: [.system(Self.system), .user(prompt)], additionalContext: ["enable_thinking": false]))
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
            var out = ""
            for await event in try await container.generate(input: input, parameters: params) {
                if let chunk = event.chunk { out += chunk }
                if Self.isLooping(out) { break }
            }
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isPlausible(out, for: raw), Self.isGrounded(out, raw: raw, vocab: vocab) else {
                return (raw, .fallbackRules)
            }
            // Guard against stopping early (seen after self-corrections, E13): if the last words said are missing,
            // clean that tail on its own and append it, so nothing the user said is silently lost.
            if allowTailRepair, let tail = Self.missingTail(raw: raw, out: out) {
                let (fixed, _) = await clean(tail, appName: appName, appType: appType, vocab: vocab,
                                             before: out, ctx: ctx, allowTailRepair: false)
                return (PromptV2.join(out, fixed, appType: appType), .model)
            }
            return (out, .model)
        } catch {
            return (raw, .fallbackRules)
        }
    }

    /// The words said after the output stopped following the transcript, if 2+ of them are real words.
    /// Uses an in-order alignment (longest common subsequence), so a common word like "you" that appeared
    /// earlier in the output can't hide a missing ending.
    static func missingTail(raw: String, out: String) -> String? {
        func norm(_ w: Substring) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
        let rawTokens = raw.split(whereSeparator: \.isWhitespace)
        let r = rawTokens.map(norm)
        let o = out.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(norm).filter { !$0.isEmpty }
        guard !r.isEmpty, !o.isEmpty, r.count < 600, o.count < 600 else { return nil }
        var dp = Array(repeating: Array(repeating: 0, count: o.count + 1), count: r.count + 1)
        for i in stride(from: r.count - 1, through: 0, by: -1) {
            for j in stride(from: o.count - 1, through: 0, by: -1) {
                dp[i][j] = r[i] == o[j] && !r[i].isEmpty ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0, lastAligned = -1
        while i < r.count && j < o.count {
            if r[i] == o[j] && !r[i].isEmpty { lastAligned = i; i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        let fillers: Set<String> = ["um", "uh", "erm", "hmm", "ah", "", "so", "and"]
        let tail = rawTokens[(lastAligned + 1)...]
        guard tail.filter({ !fillers.contains(norm($0)) }).count >= 2 else { return nil }
        return tail.joined(separator: " ")
    }

    private static func hasFiller(_ s: String) -> Bool {
        s.lowercased().range(of: #"\b(um+|uh+|erm|you know|i mean|like,)\b"#, options: .regularExpression) != nil
    }

    /// Repetition guard: the same 3-word phrase 4+ times in the last 40 words.
    static func isLooping(_ s: String) -> Bool {
        let w = s.lowercased().split(whereSeparator: \.isWhitespace).suffix(40).map(String.init)
        guard w.count >= 12 else { return false }
        var counts: [String: Int] = [:]
        for i in 0..<(w.count - 2) {
            let k = w[i...i + 2].joined(separator: " ")
            counts[k, default: 0] += 1
            if counts[k]! >= 4 { return true }
        }
        return false
    }

    /// Security: the prompt carries untrusted on-screen text (selection, text around the cursor, page names), which
    /// could try to steer the model into writing something the user never said. Require most output words to come
    /// from the transcript or the hints (prefix match tolerates "regard" → "Regards"); otherwise use the transcript.
    static func isGrounded(_ out: String, raw: String, vocab: [String]) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty }
        }
        let source = Set(words(raw + " " + vocab.joined(separator: " ")).map { String($0.prefix(4)) })
        let outWords = words(out).filter { !($0.allSatisfy(\.isNumber) && $0.count <= 2) }  // list numbers
        guard outWords.count >= 4 else { return true }
        let grounded = outWords.filter { source.contains(String($0.prefix(4))) }.count
        return Double(grounded) / Double(outWords.count) >= 0.6
    }

    /// Validator: reject replies, summaries and loops; fall back to the raw transcript.
    static func isPlausible(_ out: String, for raw: String) -> Bool {
        guard !out.isEmpty, !isLooping(out) else { return false }
        // Count words across spaces *and* newlines: "Regards,\nSam" is two words, not one.
        let words = { (t: String) in t.split(whereSeparator: \.isWhitespace).count }
        let ratio = Double(words(out)) / Double(max(words(raw), 1))
        // A self-correction legitimately shortens the text ("at 8:30, sorry, make that 10:30" → "at 10:30").
        let floor = raw.range(of: PostEdit.correctionCue, options: .regularExpression) != nil ? 0.3 : 0.6
        return ratio >= floor && ratio <= 1.4
    }
}
