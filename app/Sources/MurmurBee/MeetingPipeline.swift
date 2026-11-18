@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// After the call, everything on this Mac: speech recognition on both channels, who said what, then the notes.
/// It uses its own models rather than the ones dictation keeps loaded, so you can still dictate while it runs.
enum MeetingPipeline {
    struct Transcript: Sendable {
        var text = ""
        var you: String?
        var vocab: [String] = []
        var micWords = 0, micKept = 0, callWords = 0, speakers = 0
    }

    /// Reads mic.wav and call.wav from `dir`. `status` gets short progress lines.
    static func transcribe(dir: URL, status: @escaping @Sendable (String) -> Void) async throws -> Transcript {
        let micURL = dir.appendingPathComponent("mic.wav"), callURL = dir.appendingPathComponent("call.wav")
        status("Transcribing…")
        let modelDir = try await AsrModels.download(version: .ultra)
        try SpeechModelPin.verify(modelDir)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(try await AsrModels.load(from: modelDir, version: .ultra))
        let mic = try await words(in: micURL, asr: asr)
        let call = try await words(in: callURL, asr: asr)
        await asr.cleanup()
        guard !mic.isEmpty || !call.isEmpty else { return Transcript() }

        status("Working out who said what…")
        let diarizer = OfflineDiarizerManager(config: .default)
        try await diarizer.prepareModels()
        try SpeechModelPin.verify(OfflineDiarizerModels.defaultModelsDirectory().appendingPathComponent("speaker-diarization"),
                                  pins: SpeechModelPin.diarizerSHA256)

        var out = Transcript(micWords: mic.count, callWords: call.count)
        var spoken: [MeetingWord]
        if call.isEmpty {
            // Nothing played through the Mac: an in-person meeting, so the mic holds everyone and no voice is "you".
            let labelled = MeetingTranscript.label(MeetingTranscript.attribute(mic, try await segments(micURL, diarizer)), from: 1)
            out.speakers = Set(labelled.map(\.spk)).count
            spoken = labelled
        } else {
            let others = MeetingTranscript.label(MeetingTranscript.attribute(call, try await segments(callURL, diarizer)), from: 2)
            let converter = AudioConverter()
            let kept = MeetingTranscript.keepMicWords(mic, call: call, micAudio: try converter.resampleAudioFile(micURL),
                                                      callAudio: try converter.resampleAudioFile(callURL))
            let you = PostEdit.userNames.last ?? "You"
            out.you = you
            out.micKept = kept.count
            out.speakers = Set(others.map(\.spk)).count
            spoken = (kept.map { w in var w = w; w.spk = you; return w } + others).sorted { $0.s < $1.s }
        }
        let terms = Vocabulary.dictionary().filter { !$0.contains("@") }
        out.vocab = MeetingTranscript.select(spoken.map(\.w).joined(separator: " "), terms: terms)
        if let you = out.you, !out.vocab.contains(you) { out.vocab.append(you) }
        out.text = MeetingTranscript.turns(MeetingTranscript.snap(spoken, terms: out.vocab))
        return out
    }

    private static func words(in url: URL, asr: AsrManager) async throws -> [MeetingWord] {
        // A channel that never got any audio (no call tap) is an empty file, which isn't an error here.
        guard let file = try? AVAudioFile(forReading: url), file.length > Int64(MeetingRecorder.rate / 4) else { return [] }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(url, decoderState: &state)
        return buildWordTimings(from: result.tokenTimings ?? []).map { MeetingWord(w: $0.word, s: $0.startTime, e: $0.endTime) }
    }

    private static func segments(_ url: URL, _ diarizer: OfflineDiarizerManager) async throws -> [(Double, Double, String)] {
        try await diarizer.process(url).segments
            .map { (Double($0.startTimeSeconds), Double($0.endTimeSeconds), $0.speakerId) }
            .sorted { $0.0 < $1.0 }
    }

    /// Loads the notes model, writes the notes and lets the model go again, so its memory is only in use for this.
    /// One pass, greedy, thinking off, as in M05–M09. M06b's prompt writes more than M05's did, and its action items
    /// and decisions come last, so 1,200 tokens cut them off on longer meetings (M10).
    static func writeNotes(prompt: String, model: URL) async throws -> String {
        let notes = try await generate(prompt: prompt, model: model)
        Memory.clearCache()  // here, once the model has been released, or its weights would stay behind in MLX's cache
        return notes
    }

    private static func generate(prompt: String, model: URL) async throws -> String {
        let container = try await PersonalTrainer.loadContainer(model)
        let input = try await container.prepare(input: UserInput(chat: [.user(prompt)],
                                                                 additionalContext: ["enable_thinking": false]))
        var out = ""
        for await event in try await container.generate(input: input, parameters: GenerateParameters(maxTokens: 2400, temperature: 0)) {
            if let chunk = event.chunk { out += chunk }
            if Cleaner.isLooping(out) { break }
        }
        if let end = out.range(of: "</think>") { out = String(out[end.upperBound...]) }
        // Characters split across tokens can come out as U+FFFD (seen once with Gemma), and some models indent with
        // non-breaking spaces, which Markdown lists don't recognise.
        out = out.replacingOccurrences(of: "\u{FFFD}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
