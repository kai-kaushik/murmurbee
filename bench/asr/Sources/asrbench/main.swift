// Times Parakeet (FluidAudio, CoreML/ANE) on the test set, optionally with custom-vocabulary boosting.
// Usage: asrbench <v2|v3|ultra> <testset.jsonl> <out.jsonl> <audio-root> [vocab.txt]
import FluidAudio
import Foundation

let args = CommandLine.arguments
let version: AsrModelVersion = ["v2": .v2, "v3": .v3, "ultra": .ultra][args[1]] ?? .v2
let rows = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map {
    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
}
let root = URL(fileURLWithPath: args[4])
let vocabPath = args.count > 5 ? args[5] : nil

let t = Date()
let models = try await AsrModels.downloadAndLoad(version: version)
let asr = AsrManager(config: .default)
try await asr.loadModels(models)
print(String(format: "model %@ loaded in %.1fs", args[1], Date().timeIntervalSince(t)))

// Custom vocabulary: CTC keyword spotter + rescorer, loaded once like the app would.
func loadVocab(_ vocabPath: String?) async throws -> (CustomVocabularyContext, CtcKeywordSpotter, VocabularyRescorer)? {
    guard let vocabPath else { return nil }
    let (ctx, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: vocabPath)
    let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
    let rescorer = try await VocabularyRescorer.create(
        spotter: spotter, vocabulary: ctx,
        config: VocabularyRescorer.Config(
            shortTermCbwTaperPivot: ContextBiasingConstants.defaultShortTermCbwTaperPivot,
            spotterRescueMinSimilarity: ContextBiasingConstants.defaultSpotterRescueMinSimilarity,
            spotterRescueMultiWordMinSimilarity: ContextBiasingConstants.defaultSpotterRescueMultiWordMinSimilarity,
            spotterRescueEnabled: ContextBiasingConstants.defaultSpotterRescueEnabled),
        ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant))
    print("vocabulary: \(ctx.terms.count) terms")
    return (ctx, spotter, rescorer)
}
let vocab = try await loadVocab(vocabPath)

let converter = AudioConverter()
func run(_ samples: [Float]) async throws -> (String, Double, [String]) {
    var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let start = Date()
    let r = try await asr.transcribe(samples, decoderState: &state)
    var text = r.text
    var replaced: [String] = []
    if let (ctx, spotter, rescorer) = vocab, let timings = r.tokenTimings, !timings.isEmpty {
        let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: ctx, minScore: nil)
        if !spot.logProbs.isEmpty {
            let cfg = ContextBiasingConstants.rescorerConfig(forVocabSize: ctx.terms.count)
            let out = rescorer.ctcTokenRescore(
                transcript: r.text, tokenTimings: timings, logProbs: spot.logProbs,
                frameDuration: spot.frameDuration, cbw: Float(ProcessInfo.processInfo.environment["VOCAB_CBW"] ?? "") ?? cfg.cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: Float(ProcessInfo.processInfo.environment["VOCAB_MINSIM"] ?? "") ?? cfg.minSimilarity)
            if out.wasModified {
                text = out.text
                replaced = out.replacements.filter(\.shouldReplace).map {
                    "\($0.originalWord) -> \($0.replacementWord ?? "")"
                }
            }
        }
    }
    return (text, Date().timeIntervalSince(start) * 1000, replaced)
}

// Warm-up so first-call compilation isn't counted.
let warm = try converter.resampleAudioFile(root.appendingPathComponent(rows[0]["audioPath"] as! String))
_ = try await run(warm)

FileManager.default.createFile(atPath: args[3], contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: args[3]))
for row in rows {
    let samples = try converter.resampleAudioFile(root.appendingPathComponent(row["audioPath"] as! String))
    let (text, ms, replaced) = try await run(samples)
    let tail = Array(samples.suffix(16_000 * 8))  // what's left at key-up when chunking at pauses
    let (_, tailMs, _) = try await run(tail)
    let secs = Double(samples.count) / 16_000
    let rec: [String: Any] = [
        "id": row["transcriptEntityId"]!, "bucket": row["bucket"]!, "seconds": secs,
        "full_ms": ms, "tail8_ms": tailMs, "rtfx": secs * 1000 / ms, "text": text, "vocab_replacements": replaced,
    ]
    out.write(try JSONSerialization.data(withJSONObject: rec) + Data("\n".utf8))
    print(String(format: "%-5@ %6.1fs audio  full %5.0f ms  (%4.0fx)  last-8s %4.0f ms  %@",
                 row["bucket"] as! String, secs, ms, secs * 1000 / ms, tailMs, replaced.joined(separator: "; ")))
}
