import AppKit
import FluidAudio

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

// A regular app (Dock icon, main window) that also lives in the menu bar and keeps running when its window closes.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController()
app.delegate = controller
app.run()
