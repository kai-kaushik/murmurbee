import AppKit
import FluidAudio

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
            try await cleaner.load(from: AppController.modelDir)
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
        try await cleaner.load(from: AppController.modelDir)
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
    let ctx = PromptContext(user: "Kai Kaushik", locale: "en-GB", tz: "UTC+00:00", time: "Sun 25 Oct 2026 10:30",
                            url: "mail.google.com/mail", selected: "old text", after: " and the rest")
    print(PromptV3.userMessage(appName: "Gmail", appType: "email", raw: " hello mr vickas ",
                               vocab: ["Sam", "Kai Kaushik"], before: "Hi,\n\n", ctx: ctx), terminator: "")
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

// Menu-bar only app: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
