import AVFoundation
import FluidAudio
import Foundation

// meetbench diarize <offline|sortformer|lseend|lseend-ami> <list>   list lines: in.wav out.rttm [numSpeakers]
// meetbench transcribe <list>                            list lines: in.wav out.json
// meetbench stream <unified-320|unified-1120|unified-2080> <list>   live transcription, list lines: in.wav out.json
// meetbench record <dir>                                 records a real call (mic + call audio), see Record.swift
// Models load once; each file prints one JSON line: audio seconds, compute seconds, RTFx.
// The final line reports peak resident memory for the whole run.

struct Job { let input: URL; let output: URL; let speakers: Int? }

func readJobs(_ path: String) throws -> [Job] {
    try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").compactMap { line in
        let f = line.split(separator: " ").map(String.init)
        guard f.count >= 2 else { return nil }
        return Job(input: URL(fileURLWithPath: f[0]), output: URL(fileURLWithPath: f[1]),
                   speakers: f.count > 2 ? Int(f[2]) : nil)
    }
}

func duration(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.fileFormat.sampleRate
}

func peakMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576  // bytes on macOS
}

func emit(_ dict: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
}

/// RTTM: SPEAKER <file> 1 <start> <duration> <NA> <NA> <speaker> <NA> <NA>
func writeRTTM(_ segments: [(String, Double, Double)], file: String, to url: URL) throws {
    let lines = segments.sorted { $0.1 < $1.1 }.filter { $0.2 > $0.1 }.map { s in
        String(format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> %@ <NA> <NA>", file, s.1, s.2 - s.1, s.0)
    }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

func timeline(_ t: DiarizerTimeline) -> [(String, Double, Double)] {
    t.speakers.flatMap { index, speaker in
        speaker.finalizedSegments.map { ("spk\(index)", Double($0.startTime), Double($0.endTime)) }
    }
}

func sortformerConfig(_ engine: String) -> SortformerConfig {
    switch engine {
    case "sortformer-balanced": return .balancedV2_1
    case "sortformer-efficient": return .efficientV2_1
    default: return .highContextV2_1
    }
}

func diarize(engine: String, jobs: [Job]) async throws {
    var offline: OfflineDiarizerManager?
    var offlineModels: OfflineDiarizerModels?
    var sortformer: SortformerModels?
    var lseend: LSEENDModel?
    let loadStart = Date()
    switch engine {
    case "offline":
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        offline = manager
        offlineModels = try await OfflineDiarizerModels.load(from: OfflineDiarizerModels.defaultModelsDirectory())
    case "sortformer-balanced", "sortformer-efficient":
        // The live configs (~1 s and ~2 s output latency); "sortformer" above is ~30 s behind.
        sortformer = try await SortformerModels.loadFromHuggingFace(config: sortformerConfig(engine))
    case "sortformer":
        // Streaming high-context config: the whole-file Sortformer diarizes each 30 s window on its own and
        // confuses speakers across a long meeting (FluidAudio Benchmarks.md: 56.7% vs 26.4% DER on AMI).
        sortformer = try await SortformerModels.loadFromHuggingFace(config: .highContextV2_1)
    case "lseend", "lseend-ami":
        // dihard3 is the general model; ami is fine-tuned on AMI's training meetings (in-domain).
        lseend = try await LSEENDModel.loadFromHuggingFace(variant: engine == "lseend" ? .dihard3 : .ami,
                                                           stepSize: .step500ms, computeUnits: .cpuOnly)
    default:
        throw NSError(domain: "meetbench", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown engine \(engine)"])
    }
    emit(["event": "loaded", "engine": engine, "seconds": Date().timeIntervalSince(loadStart)])

    for job in jobs {
        let name = job.input.deletingPathExtension().lastPathComponent
        let audio = try duration(job.input)
        let start = Date()
        var segments: [(String, Double, Double)] = []
        switch engine {
        case "offline":
            // A fixed speaker count needs its own manager; otherwise reuse the loaded one.
            var manager = offline!
            if let n = job.speakers {
                manager = OfflineDiarizerManager(config: OfflineDiarizerConfig.default.withSpeakers(exactly: n))
                manager.initialize(models: offlineModels!)
            }
            let result = try await manager.process(job.input)
            segments = result.segments.map { ($0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds)) }
        case "sortformer", "sortformer-balanced", "sortformer-efficient":
            let d = SortformerDiarizer(config: sortformerConfig(engine))
            d.initialize(models: sortformer!)
            segments = timeline(try d.processComplete(audioFileURL: job.input))
        default:
            let d = try LSEENDDiarizer(model: lseend!)
            segments = timeline(try d.processComplete(audioFileURL: job.input))
        }
        let compute = Date().timeIntervalSince(start)
        try writeRTTM(segments, file: name, to: job.output)
        emit(["event": "file", "file": name, "audio_s": audio, "compute_s": compute, "rtfx": audio / compute,
              "speakers_found": Set(segments.map(\.0)).count])
    }
    emit(["event": "done", "peak_rss_mb": peakMB()])
}

func transcribe(jobs: [Job]) async throws {
    let loadStart = Date()
    let dir = try await AsrModels.download(version: .ultra)
    let models = try await AsrModels.load(from: dir, version: .ultra)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    emit(["event": "loaded", "engine": "parakeet-ultra", "seconds": Date().timeIntervalSince(loadStart)])
    for job in jobs {
        let name = job.input.deletingPathExtension().lastPathComponent
        let audio = try duration(job.input)
        let start = Date()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(job.input, decoderState: &state)
        let compute = Date().timeIntervalSince(start)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            ["w": $0.word, "s": $0.startTime, "e": $0.endTime] as [String: Any]
        }
        let out = try JSONSerialization.data(withJSONObject: ["file": name, "text": result.text, "words": words])
        try out.write(to: job.output)
        emit(["event": "file", "file": name, "audio_s": audio, "compute_s": compute, "rtfx": audio / compute,
              "words": words.count])
    }
    emit(["event": "done", "peak_rss_mb": peakMB()])
}

/// Live transcription: the file is fed in 80 ms buffers, as a microphone would deliver it, and each word records
/// how much audio had been fed when it first appeared ("emit", seconds). Latency = emit - word end, plus compute.
func stream(engine: String, jobs: [Job]) async throws {
    let variants: [String: StreamingModelVariant] = [
        "unified-320": .parakeetUnified320ms, "unified-1120": .parakeetUnified1120ms,
        "unified-2080": .parakeetUnified2080ms,
    ]
    guard let variant = variants[engine],
        let asr = variant.createManager() as? StreamingUnifiedAsrManager
    else { throw NSError(domain: "meetbench", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown engine \(engine)"]) }
    let loadStart = Date()
    try await asr.loadModels()
    emit(["event": "loaded", "engine": engine, "seconds": Date().timeIntervalSince(loadStart)])
    let step: AVAudioFrameCount = 1280
    for job in jobs {
        let name = job.input.deletingPathExtension().lastPathComponent
        let file = try AVAudioFile(forReading: job.input)
        let audio = Double(file.length) / file.fileFormat.sampleRate
        try await asr.reset()
        var tokens: [(TokenTiming, Double)] = []
        var fed = 0.0
        var stepTimes: [Double] = []
        let start = Date()
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: step)!
            try file.read(into: buffer, frameCount: step)
            fed += Double(buffer.frameLength) / file.fileFormat.sampleRate
            let t0 = Date()
            try await asr.appendAudio(buffer)
            try await asr.processBufferedAudio()
            tokens += await asr.consumeTokenTimings().map { ($0, fed) }
            stepTimes.append(Date().timeIntervalSince(t0))
        }
        _ = try await asr.finish()
        tokens += await asr.consumeTokenTimings().map { ($0, audio) }
        let compute = Date().timeIntervalSince(start)
        // Group sub-word pieces into words on the word-boundary marker; a word appears when its last piece does.
        var words: [[String: Any]] = []
        for (t, at) in tokens where !t.token.isEmpty && t.token != "<blank>" && t.token != "<pad>" {
            let boundary = t.token.hasPrefix("\u{2581}") || t.token.hasPrefix(" ")
            let piece = boundary ? String(t.token.dropFirst()) : t.token
            if boundary || words.isEmpty {
                words.append(["w": piece, "s": t.startTime, "e": t.endTime, "emit": at])
            } else {
                words[words.count - 1]["w"] = (words[words.count - 1]["w"] as! String) + piece
                words[words.count - 1]["e"] = t.endTime
                words[words.count - 1]["emit"] = at
            }
        }
        words = words.filter { !(($0["w"] as! String).trimmingCharacters(in: .whitespaces).isEmpty) }
        let sorted = stepTimes.sorted()
        let out = try JSONSerialization.data(withJSONObject: ["file": name, "words": words])
        try out.write(to: job.output)
        emit(["event": "file", "file": name, "audio_s": audio, "compute_s": compute, "rtfx": audio / compute,
              "words": words.count, "step_ms_median": 1000 * sorted[sorted.count / 2],
              "step_ms_p99": 1000 * sorted[Int(Double(sorted.count) * 0.99)], "step_ms_max": 1000 * sorted.last!])
    }
    emit(["event": "done", "peak_rss_mb": peakMB()])
}

let args = CommandLine.arguments
do {
    switch args.count > 1 ? args[1] : "" {
    case "diarize" where args.count == 4: try await diarize(engine: args[2], jobs: readJobs(args[3]))
    case "transcribe" where args.count == 3: try await transcribe(jobs: readJobs(args[2]))
    case "stream" where args.count == 4: try await stream(engine: args[2], jobs: readJobs(args[3]))
    case "record" where args.count == 3: try await record(to: URL(fileURLWithPath: args[2]))
    default:
        FileHandle.standardError.write("usage: meetbench diarize <offline|sortformer|sortformer-balanced|sortformer-efficient|lseend|lseend-ami> <list> | transcribe <list> | stream <unified-320|unified-1120|unified-2080> <list> | record <dir>\n".data(using: .utf8)!)
        exit(2)
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
