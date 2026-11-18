import AVFoundation
import AppKit
import FluidAudio
import MLX

final class TimeBox: @unchecked Sendable {
    private var start: Date?
    private let lock = NSLock()
    func startIfNeeded() -> Date { lock.lock(); defer { lock.unlock() }; if start == nil { start = Date() }; return start! }
}

// The personal-training helper the app launches (see PersonalTrainer): MurmurBee --train-personal <name> [--resume]
// Prints "P …" progress lines, then "R …" (result) or "E …" (error). Exit 2 = GPU fault, resumable.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--train-personal" {
    setvbuf(stdout, nil, _IOLBF, 0)
    signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN)
    let pauseSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
    pauseSource.setEventHandler { PersonalTrainer.pause.set(true) }
    pauseSource.resume()
    let resumeSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .global())
    resumeSource.setEventHandler { PersonalTrainer.pause.set(false) }
    resumeSource.resume()
    let user = CommandLine.arguments[2], resume = CommandLine.arguments.contains("--resume")
    Task {
        do {
            let o = try await PersonalTrainer.run(store: Store(), user: user, resume: resume) { p in
                switch p {
                case .preparing: print("P prep")
                case .checkingCurrent(let d, let t): print("P cur \(d) \(t)")
                case .training(let s, let n, let l): print("P train \(s) \(n) \(l.map { String($0) } ?? "")")
                case .checkingNew(let d, let t): print("P new \(d) \(t)")
                default: break
                }
            }
            print("R \(o.installed ? 1 : 0) \(o.currentWER) \(o.newWER) \(o.examples) \(o.heldOut) \(o.minutes)")
            exit(0)
        } catch let e as PersonalTrainer.TrainError {
            if case .gpu = e { print("E gpu \(e.localizedDescription)"); exit(2) }
            print("E error \(e.localizedDescription)"); exit(1)
        } catch {
            print("E error \(error.localizedDescription)"); exit(1)
        }
    }
    RunLoop.main.run()
}

// A short personal-training run that installs nothing:  MurmurBee --train-test <steps> <held-out>
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--train-test" {
    let steps = Int(CommandLine.arguments[2]) ?? 30, held = Int(CommandLine.arguments[3]) ?? 10
    Task {
        let t0 = Date()
        let trainStart = TimeBox()
        do {
            let o = try await PersonalTrainer.run(store: Store(), user: "Kai Kaushik", steps: steps, heldLimit: held,
                                                  install: false) { p in
                if case .training(let s, let n, let l) = p {
                    let start = trainStart.startIfNeeded()
                    print(String(format: "step %d/%d loss %.3f  (%.2f s/step)", s, n, l ?? -1,
                                 Date().timeIntervalSince(start) / Double(s)))
                }
            }
            print(String(format: "examples %d, held out %d, current WER %.3f, new WER %.3f, %.1f min total",
                         o.examples, o.heldOut, o.currentWER, o.newWER, Date().timeIntervalSince(t0) / 60))
        } catch { print("failed:", error.localizedDescription) }
        exit(0)
    }
    RunLoop.main.run()
}

#if DEBUG
// Developer test modes, left out of release builds.

// Imports Wispr Flow's history into a scratch database twice (to check nothing is added twice); never touches the
// real history or dictionary:  MurmurBee --import-wispr-test <scratch.sqlite>
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--import-wispr-test" {
    let store = Store(path: CommandLine.arguments[2])
    Task {
        print("found:", WisprImport.scan().map { "\($0.dictations) dictations, \($0.words) words" } ?? "none")
        let t = Date()
        let a = try await WisprImport.run(into: store, writeDictionary: false) { _, _ in }
        print(String(format: "first run: %d dictations, %d words, %.1fs", a.dictations, a.words, Date().timeIntervalSince(t)))
        let b = try await WisprImport.run(into: store, writeDictionary: false) { _, _ in }
        print("second run: \(b.dictations) new dictations")
        for h in await store.history(limit: 3) { print("-", h.date, h.app, "|", h.text.prefix(70)) }
        exit(0)
    }
    RunLoop.main.run()
}

// Prints the weekly totals report for a history database without sending it:  MurmurBee --totals-check <history.sqlite>
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--totals-check" {
    let store = Store(path: CommandLine.arguments[2])
    Task { @MainActor in
        let u = await store.usage(since: Date().addingTimeInterval(-7 * 24 * 3600))
        print("first dictation:", u.first.map { "\($0)" } ?? "none")
        let props = WeeklyTotals.properties(u)
        for k in props.keys.sorted() { print(" ", k, "=", props[k]!) }
        exit(0)
    }
    RunLoop.main.run()
}

// Installs a cleanup model package the way first run does:  MurmurBee --fetch-model <url> <sha256> [name]
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--fetch-model" {
    let a = CommandLine.arguments
    let remote = ModelStore.Remote(name: a.count > 4 ? a[4] : ModelStore.general.name, url: URL(string: a[2])!,
                                   sha256: a[3])
    Task {
        do {
            let dir = try await ModelStore.download(remote) { p in print(String(format: "%.0f%%", p * 100)) }
            print("installed \(dir.path), rank \(ModelStore.rank(of: dir)); best now \(ModelStore.best()?.lastPathComponent ?? "none")")
            exit(0)
        } catch { print("failed: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
}

// Headless check of both engines inside the real bundle:  MurmurBee --selftest <file.wav>
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--selftest" {
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    let transcriber = Transcriber(), cleaner = Cleaner()
    Task {
        do {
            var t = Date()
            try await transcriber.load()
            print(String(format: "parakeet loaded %.1fs", Date().timeIntervalSince(t)))
            t = Date()
            guard let dir = AppController.modelDir else { print("No cleanup model installed in \(ModelStore.directory.path)"); exit(1) }
            try await cleaner.load(from: dir)
            print(String(format: "cleaner loaded %.1fs", Date().timeIntervalSince(t)))
            let samples = try AudioConverter().resampleAudioFile(url)
            t = Date()
            let raw = try await transcriber.transcribe(samples)
            print(String(format: "asr %.0f ms: %@", Date().timeIntervalSince(t) * 1000, raw))
            t = Date()
            let (clean, path) = await cleaner.clean(raw, appName: "Claude", appType: "AI assistant prompt")
            print(String(format: "clean %.0f ms [%@]: %@", Date().timeIntervalSince(t) * 1000, path.rawValue, clean))
            exit(0)
        } catch {
            print("selftest failed: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Runs the cleanup path on text exactly as the app does (model + tail repair + post-edits):
//   MurmurBee --clean-text <appName> <appType> <vocab;separated> <raw text>
if CommandLine.arguments.count >= 6, CommandLine.arguments[1] == "--clean-text" {
    let a = CommandLine.arguments
    let cleaner = Cleaner()
    Task {
        guard let dir = AppController.modelDir else { print("No cleanup model installed in \(ModelStore.directory.path)"); exit(1) }
        try await cleaner.load(from: dir)
        let vocab = a[4].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } + PostEdit.userNames
        let (out, path) = await cleaner.clean(a[5], appName: a[2], appType: a[3], vocab: vocab)
        let final = PostEdit.fixSignoff(PostEdit.snapNames(out, vocab: vocab), appType: a[3])
        print("[\(path.rawValue)] \(final)")
        exit(0)
    }
    RunLoop.main.run()
}

// Feeds a file through a recorder track as a device would, in 4,096-frame buffers starting `offset` seconds in, so
// format conversion and alignment can be checked without a call:  MurmurBee --track-test <in.wav> <out.wav> <offset>
if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--track-test" {
    let a = CommandLine.arguments
    do {
        let source = try AVAudioFile(forReading: URL(fileURLWithPath: a[2]))
        let t0 = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let track = try MeetingRecorder.Track(URL(fileURLWithPath: a[3]), start: t0)
        var at = t0 + (Double(a[4]) ?? 0)
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096)!
        while source.framePosition < source.length {
            try source.read(into: buffer, frameCount: 4096)
            track.write(buffer, hostTime: AVAudioTime.hostTime(forSeconds: at))
            at += Double(buffer.frameLength) / source.processingFormat.sampleRate
        }
        track.close()
        let out = try AVAudioFile(forReading: URL(fileURLWithPath: a[3]))
        print(String(format: "in %.2fs at %.0f Hz, %d ch; out %.2fs at %.0f Hz, heard: %@", Double(source.length) / source.fileFormat.sampleRate,
                     source.fileFormat.sampleRate, source.fileFormat.channelCount, Double(out.length) / out.fileFormat.sampleRate,
                     out.fileFormat.sampleRate, track.heard == nil ? "no" : "yes"))
        exit(0)
    } catch { print("failed: \(error)"); exit(1) }
}

// Downloads a model package in parts into a folder of your choosing, as first use of meetings does:
//   MurmurBee --fetch-parts <base url> <sha256> <parts> <folder>
if CommandLine.arguments.count >= 6, CommandLine.arguments[1] == "--fetch-parts" {
    let a = CommandLine.arguments
    let remote = ModelStore.Remote(name: "fetch-test", url: URL(string: a[2])!, sha256: a[3], parts: Int(a[4]) ?? 1)
    Task {
        do {
            let dir = try await ModelStore.download(remote, into: URL(fileURLWithPath: a[5])) { _ in }
            print("installed \(dir.path)")
            exit(0)
        } catch { print("failed: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
}

// Runs a recording through the whole meeting pipeline, as the app does after a call:
//   MurmurBee --meeting-test <dir with mic.wav and call.wav> <notes model dir> [typed notes file]
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--meeting-test" {
    let a = CommandLine.arguments
    Task {
        do {
            var t = Date()
            let r = try await MeetingPipeline.transcribe(dir: URL(fileURLWithPath: a[2])) { print($0) }
            print(String(format: "transcript %.1fs: mic %d words, %d kept, call %d words, %d speakers, you %@, vocab %d",
                         Date().timeIntervalSince(t), r.micWords, r.micKept, r.callWords, r.speakers, r.you ?? "-", r.vocab.count))
            let typed = a.count > 4 ? (try String(contentsOfFile: a[4], encoding: .utf8)) : ""
            try r.text.write(toFile: a[2] + "/app-transcript.txt", atomically: true, encoding: .utf8)
            t = Date()
            let notes = try await MeetingPipeline.writeNotes(prompt: MeetingPrompt.notes(you: r.you, vocab: r.vocab, typed: typed, transcript: r.text),
                                                             model: URL(fileURLWithPath: a[3]))
            try notes.write(toFile: a[2] + "/app-notes.md", atomically: true, encoding: .utf8)
            print(String(format: "notes %.1fs, %d words", Date().timeIntervalSince(t), notes.split(whereSeparator: \.isWhitespace).count))
            exit(0)
        } catch { print("failed: \(error)"); exit(1) }
    }
    RunLoop.main.run()
}

// Downloads the small files of the accurate notes model the way the app downloads all of them (Hugging Face, pinned
// commit, hash per file), into a folder of your choosing:  MurmurBee --fetch-pinned-test <folder>
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--fetch-pinned-test" {
    let full = ModelStore.accurateNotes
    let small = ModelStore.PinnedRepo(name: "pinned-test", repo: full.repo, revision: full.revision,
                                      files: full.files.filter { $0.value.1 < 50_000_000 })
    Task {
        do {
            let dir = try await ModelStore.download(small, into: URL(fileURLWithPath: CommandLine.arguments[2])) { _ in }
            print("installed \(small.files.count) files in \(dir.path)")
            var bad = small
            bad = ModelStore.PinnedRepo(name: "pinned-bad", repo: full.repo, revision: full.revision,
                                        files: ["config.json": (String(repeating: "0", count: 64), 12180)])
            do { _ = try await ModelStore.download(bad, into: URL(fileURLWithPath: CommandLine.arguments[2])) { _ in }; print("bad hash accepted") }
            catch { print("bad hash refused: \(error.localizedDescription)") }
            exit(0)
        } catch { print("failed: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
}

// Checks the rules for stopping by itself on a few made-up moments:  MurmurBee --autostop-check
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--autostop-check" {
    let cases: [(String, AutoStop.State, Bool)] = [
        ("mid-call, both talking", .init(elapsed: 600, sawCallApp: true, sinceCallApp: 1, sinceCallSound: 2, sinceMicSound: 1), false),
        ("mid-call, long pause", .init(elapsed: 600, sawCallApp: true, sinceCallApp: 1, sinceCallSound: 60, sinceMicSound: 60), false),
        ("call app gone, others quiet 16 s", .init(elapsed: 600, sawCallApp: true, sinceCallApp: 16, sinceCallSound: 16, sinceMicSound: 3), true),
        ("call app gone, music still playing", .init(elapsed: 600, sawCallApp: true, sinceCallApp: 40, sinceCallSound: 0, sinceMicSound: 30), false),
        ("call app gone for 2 min, music playing", .init(elapsed: 600, sawCallApp: true, sinceCallApp: 120, sinceCallSound: 0, sinceMicSound: 30), true),
        ("app still holds mic, 3 min of silence", .init(elapsed: 900, sawCallApp: true, sinceCallApp: 0, sinceCallSound: 200, sinceMicSound: 190), true),
        ("in person, you presenting", .init(elapsed: 900, sawCallApp: false, sinceCallApp: 900, sinceCallSound: 900, sinceMicSound: 2), false),
        ("in person, room empty 3 min", .init(elapsed: 900, sawCallApp: false, sinceCallApp: 900, sinceCallSound: 900, sinceMicSound: 185), true),
    ]
    var ok = true
    for (name, state, stops) in cases {
        let r = AutoStop.reason(state)
        ok = ok && (r != nil) == stops
        print((r != nil) == stops ? "ok  " : "FAIL", name, "->", r ?? "keeps recording")
    }
    exit(ok ? 0 : 1)
}

// Writes notes for a transcript file, without any audio:
//   MurmurBee --notes-test <transcript> <notes model dir> <out> [typed notes file] [your name] [spellings, ;-separated]
if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--notes-test" {
    let a = CommandLine.arguments
    Task {
        do {
            let t = Date()
            let typed = a.count > 5 && !a[5].isEmpty ? (try String(contentsOfFile: a[5], encoding: .utf8)) : ""
            let you = a.count > 6 ? a[6] : nil
            let vocab = a.count > 7 ? a[7].components(separatedBy: "; ") : []
            let prompt = MeetingPrompt.notes(you: you, vocab: vocab, typed: typed, transcript: try String(contentsOfFile: a[2], encoding: .utf8))
            let notes = try await MeetingPipeline.writeNotes(prompt: prompt, model: URL(fileURLWithPath: a[3]))
            try notes.write(toFile: a[4], atomically: true, encoding: .utf8)
            print(String(format: "notes %.1fs, %d words, memory left in use %.2f GB", Date().timeIntervalSince(t),
                         notes.split(whereSeparator: \.isWhitespace).count,
                         Double(Memory.activeMemory + Memory.cacheMemory) / 1e9))
            exit(0)
        } catch { print("failed: \(error)"); exit(1) }
    }
    RunLoop.main.run()
}

// Prints a fixed prompt v3 so it can be diffed against scripts/prompt_v3.py (train/serve parity):
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--prompt-check" {
    let ctx = PromptContext(user: "Sam Rivera", locale: "en-GB", tz: "UTC+00:00", time: "Sun 25 Oct 2026 10:30",
                            url: "mail.google.com/mail", selected: "old text", after: " and the rest")
    print(PromptV3.userMessage(appName: "Gmail", appType: "email", raw: " hello mr vickas ",
                               vocab: ["Priyanka", "Sam Rivera"], before: "Hi,\n\n", ctx: ctx), terminator: "")
    exit(0)
}

// Checks edit learning on saved files:  MurmurBee --learn-check <inserted> <after> <later>
if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--learn-check" {
    let read = { (p: String) in (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    let (ins, after, later) = (read(CommandLine.arguments[2]), read(CommandLine.arguments[3]), read(CommandLine.arguments[4]))
    let span = EditLearner.editedSpan(inserted: ins, after: after, later: later)
    print("span found:", span != nil)
    print("learned:", EditLearner.learnedTerms(inserted: ins, edited: span ?? "", known: []))
    exit(0)
}

// Renders the windows to PNGs for review:  MurmurBee --snapshot <dir>
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--snapshot" {
    MainActor.assumeIsolated { Snapshots.render(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
    exit(0)
}

#endif

// A regular app (Dock icon, main window) that also lives in the menu bar and keeps running when its window closes.
let app = MurmurBeeApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController()
app.delegate = controller
app.run()
