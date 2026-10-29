import CoreAudio
import AppKit
import Foundation

/// One dictation. While the key is held, audio is cut at natural pauses and each finished chunk is
/// transcribed (Neural Engine) and cleaned (GPU) in the background. Releasing the key only has to
/// process the final chunk. This is the "do the work while you talk" idea from the PRD.
@MainActor
final class Session {
    /// `written` is everything cleaned so far this dictation, joined (PromptV2.join).
    struct Chunk: Sendable {
        var raw = "", cleaned = "", path = "", vocab: [String] = [], asrMs = 0.0, cleanMs = 0.0
        /// Cleaned pieces so far and the raw text behind the last one; `written` is their join.
        var pieces: [String] = [], lastRaw = "", written = ""
    }

    /// A chunk that opens like this is probably correcting the end of the previous one.
    nonisolated static func startsWithCorrection(_ raw: String) -> Bool {
        raw.range(of: #"^\W*(um |uh )?(no wait|wait no|sorry|i mean|no,? actually|actually|correct that|scratch that|or rather|no no|let me rephrase)\b"#,
                  options: [.regularExpression, .caseInsensitive]) != nil
    }
    struct Result { var raw: String, cleaned: String, paths: String, vocab: [String], chunks: Int, durationS: Double,
                    asrFinalMs: Double, cleanFinalMs: Double }

    private let recorder: Recorder
    private let transcriber: Transcriber
    private let cleaner: Cleaner
    private let context: ContextSnapshot
    private let cleanupOn: Bool
    private var committed = 0
    private var tasks: [Task<Chunk, Never>] = []
    private var poller: Task<Void, Never>?
    private let dictionary = Vocabulary.dictionary()
    /// On-screen names, gathered off the main thread after key-down; awaited by the first cleanup.
    var screenNames: Task<[String], Never> = Task { [] }
    var onLevel: (Float) -> Void = { _ in }

    private static let sr = Int(Recorder.sampleRate)
    private static let frame = sr * 30 / 1000  // 30 ms analysis frames

    init(recorder: Recorder, transcriber: Transcriber, cleaner: Cleaner, context: ContextSnapshot, cleanupOn: Bool) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.context = context
        self.cleanupOn = cleanupOn
    }

    func start(device: AudioDeviceID? = nil) throws {
        try recorder.start(device: device)
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                self.onLevel(self.recorder.currentLevel)
                self.maybeCut()
            }
        }
    }

    func cancel() {
        poller?.cancel()
        recorder.stop()
        tasks.forEach { $0.cancel() }
    }

    func finish() async -> Result {
        poller?.cancel()
        recorder.stop()
        let total = recorder.count
        if total - committed > Self.sr / 4 { schedule(committed, total) }
        var chunks: [Chunk] = []
        for t in tasks { chunks.append(await t.value) }
        let last = chunks.last ?? Chunk()
        func join(_ parts: [String]) -> String {
            parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        // Lists are formatted once over the whole text: a chunk can't know a list is coming (PostEditLists.swift).
        let written = cleanupOn ? PostEdit.formatSpokenList(last.written) : last.written
        return Result(raw: join(chunks.map(\.raw)), cleaned: PostEdit.fixSignoff(written, appType: context.appType),
                      paths: chunks.map(\.path).joined(separator: ","),
                      vocab: Array(Set(chunks.flatMap(\.vocab))).sorted(), chunks: chunks.count,
                      durationS: Double(total) / Double(Self.sr), asrFinalMs: last.asrMs, cleanFinalMs: last.cleanMs)
    }

    /// Cut a chunk once there are 6+ s pending and a 300 ms pause to cut at; force a cut at 20 s.
    private func maybeCut() {
        let end = recorder.count
        let pending = end - committed
        guard pending >= Self.sr * 6 else { return }
        let lo = committed + Self.sr * 4, hi = end - Self.sr / 5
        guard hi > lo else { return }
        let audio = recorder.snapshot(from: lo, to: hi)
        let rms = stride(from: 0, to: audio.count - Self.frame, by: Self.frame).map { i -> Float in
            var s: Float = 0
            for j in i..<(i + Self.frame) { s += audio[j] * audio[j] }
            return sqrt(s / Float(Self.frame))
        }
        guard !rms.isEmpty else { return }
        let sorted = rms.sorted()
        let threshold = max(0.004, sorted[sorted.count / 2] * 0.2)
        var cut: Int?
        var run = 0
        for (i, r) in rms.enumerated() {
            run = r < threshold ? run + 1 : 0
            if run >= 10 { cut = i - run / 2 }  // latest pause of 300 ms+, cut in its middle
        }
        if cut == nil && pending >= Self.sr * 20 { cut = rms.indices.min { rms[$0] < rms[$1] } }
        guard let cut else { return }
        let at = lo + cut * Self.frame
        schedule(committed, at)
        committed = at
    }

    /// Speech for chunk N runs as soon as it's cut; its cleanup waits for chunk N-1's text, so every chunk
    /// is cleaned knowing what came before it (list numbering, email layout, mid-sentence continuations).
    private func schedule(_ start: Int, _ end: Int) {
        let samples = recorder.snapshot(from: start, to: end)
        let (transcriber, cleaner, ctx, cleanupOn, dictionary) = (transcriber, cleaner, context, cleanupOn, dictionary)
        let previous = tasks.last
        let screen = screenNames
        tasks.append(Task.detached {
            var c = Chunk()
            let t0 = Date()
            c.raw = (try? await transcriber.transcribe(samples)) ?? ""
            c.asrMs = Date().timeIntervalSince(t0) * 1000
            let prev = await previous?.value
            var pieces = prev?.pieces ?? []
            var raw = c.raw
            // Self-correction across a pause ("…on Tuesday." | "sorry, Wednesday"): re-clean this chunk
            // together with the previous one, and replace the previous piece.
            if cleanupOn, let prev, !prev.lastRaw.isEmpty, Session.startsWithCorrection(raw) {
                raw = prev.lastRaw + " " + raw
                pieces.removeLast()
            }
            let written = pieces.reduce("") { PromptV2.join($0, $1, appType: ctx.appType) }
            let t1 = Date()
            if cleanupOn && !raw.isEmpty {
                let vocab = Array(NSOrderedSet(array: Vocabulary.select(raw: raw, screen: await screen.value,
                                                                         dictionary: dictionary) + PostEdit.userNames)
                    .compactMap { $0 as? String }.prefix(PromptV2.maxVocab))
                let before = written.isEmpty ? ctx.beforeCursor : written
                c.vocab = vocab
                let clock = ContextSnapshot.clock()
                let pctx = PromptContext(user: PostEdit.userNames.first ?? "", locale: clock.locale, tz: clock.tz,
                                         time: clock.time, url: ctx.url, selected: ctx.selectedText, after: ctx.afterCursor)
                let (text, path) = await cleaner.clean(raw, appName: ctx.appName, appType: ctx.appType,
                                                       vocab: vocab, before: before, ctx: pctx)
                c.cleaned = PostEdit.snapNames(text, vocab: vocab)
                c.path = raw == c.raw ? path.rawValue : path.rawValue + "+merged"
            } else {
                c.cleaned = raw
                c.path = cleanupOn ? Cleaner.Path.skip.rawValue : Cleaner.Path.off.rawValue
            }
            c.cleanMs = Date().timeIntervalSince(t1) * 1000
            if !c.cleaned.isEmpty { pieces.append(c.cleaned) }
            c.pieces = pieces
            c.lastRaw = raw
            c.written = pieces.reduce("") { PromptV2.join(PostEdit.dropFalseStop($0, before: $1), $1, appType: ctx.appType) }
            return c
        })
    }
}
