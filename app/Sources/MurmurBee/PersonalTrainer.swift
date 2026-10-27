import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXOptimizers
import Observation
import Tokenizers

/// On-device personal training: a LoRA adapter on top of the general cleanup model, trained on your own history
/// (raw transcript → what you kept), entirely on this Mac. The newest dictations are held out; the new adapter is
/// only switched in if it beats the model you're using on them (the "shadow gate" from the PRD).
@MainActor
@Observable
final class PersonalTrainer {
    static let shared = PersonalTrainer()

    enum Phase: Equatable {
        case idle
        case preparing
        case checkingCurrent(done: Int, total: Int)
        case training(step: Int, total: Int, loss: Float?)
        case checkingNew(done: Int, total: Int)
        case finished(Outcome)
        case failed(String)
    }

    struct Outcome: Equatable, Sendable {
        let installed: Bool
        let currentWER: Double
        let newWER: Double
        let examples: Int
        let heldOut: Int
        let minutes: Double
    }

    var store: Store?
    var userName = ""
    private(set) var phase: Phase = .idle
    private(set) var available = 0  // usable training examples in history
    var running: Bool {
        switch phase { case .idle, .finished, .failed: false; default: true }
    }

    /// Set while you're dictating: training waits so it never slows a dictation down.
    nonisolated static let pause = Flag()
    nonisolated static let cancel = Flag()

    /// Personal adapter directory (inside the models folder; picked by ModelStore when it ranks highest).
    nonisolated static var personalDir: URL { ModelStore.directory.appendingPathComponent("personal") }
    nonisolated static let generalName = "murmurbee-cleanup-v1"

    func refresh() {
        guard let store else { return }
        Task {
            let rows = await store.trainingRows()
            available = Self.examples(from: rows, user: "").count
        }
    }

    // MARK: - Helper process
    //
    // Training runs in a separate process (`MurmurBee --train-personal`), so a GPU fault (macOS's GPU watchdog can
    // abort a long training step) only ends the helper, never MurmurBee itself. The helper checkpoints every 200
    // steps; if it dies, the app restarts it from the last checkpoint, up to 3 attempts.

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var gotResult = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var lastError: String?
    nonisolated static let childPID = Counter()

    /// Pause or resume training (e.g. while dictating), in-process and in the helper.
    nonisolated static func setPaused(_ paused: Bool) {
        pause.set(paused)
        let pid = childPID.get()
        if pid > 0 { kill(pid_t(pid), paused ? SIGUSR1 : SIGUSR2) }
    }

    func start() {
        guard !running else { return }
        phase = .preparing
        Self.log("start")
        launch(resume: false, attempt: 1)
    }

    /// A small local log of training runs (starts, restarts, results), so a run's history can be checked afterwards.
    nonisolated static func log(_ line: String) {
        let url = ModelStore.directory.deletingLastPathComponent().appendingPathComponent("training.log")
        let entry = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
    }

    private func launch(resume: Bool, attempt: Int) {
        gotResult = false; stopping = false; lastError = nil
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--train-personal", userName] + (resume ? ["--resume"] : [])
        var env = ProcessInfo.processInfo.environment
        // Smaller Metal command buffers: each finishes well inside the GPU watchdog's limit.
        env["MLX_MAX_OPS_PER_BUFFER"] = env["MLX_MAX_OPS_PER_BUFFER"] ?? "30"
        env["MLX_MAX_MB_PER_BUFFER"] = env["MLX_MAX_MB_PER_BUFFER"] ?? "300"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let lines = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            for line in lines.append(h.availableData) {
                Task { @MainActor in PersonalTrainer.shared.handle(line) }
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus, crashed = proc.terminationReason == .uncaughtSignal
            Task { @MainActor in PersonalTrainer.shared.ended(status: status, crashed: crashed, attempt: attempt) }
        }
        do {
            try p.run()
            process = p
            Self.childPID.set(Int(p.processIdentifier))
            if Self.pause.get() { kill(p.processIdentifier, SIGUSR1) }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// One line of helper output: "P <phase> …", "R <outcome>" or "E <kind> <message>".
    private func handle(_ line: String) {
        let f = line.split(separator: " ").map(String.init)
        guard let tag = f.first else { return }
        func i(_ k: Int) -> Int { f.count > k ? Int(f[k]) ?? 0 : 0 }
        func d(_ k: Int) -> Double { f.count > k ? Double(f[k]) ?? 0 : 0 }
        switch (tag, f.count > 1 ? f[1] : "") {
        case ("P", "prep"): phase = .preparing
        case ("P", "cur"): phase = .checkingCurrent(done: i(2), total: i(3))
        case ("P", "train"): phase = .training(step: i(2), total: i(3), loss: f.count > 4 ? Float(f[4]) : nil)
        case ("P", "new"): phase = .checkingNew(done: i(2), total: i(3))
        case ("R", _):
            gotResult = true
            Self.log("result " + f.dropFirst().joined(separator: " "))
            let o = Outcome(installed: f[1] == "1", currentWER: d(2), newWER: d(3), examples: i(4), heldOut: i(5),
                            minutes: d(6))
            phase = .finished(o)
            if o.installed { NotificationCenter.default.post(name: .personalModelInstalled, object: nil) }
        case ("E", _):
            lastError = f.dropFirst(2).joined(separator: " ")
            Self.log("error " + f.dropFirst().joined(separator: " "))
        case ("V", _):
            Self.log("validation step \(i(1)) wer \(d(2))")
        default: break
        }
    }

    private func ended(status: Int32, crashed: Bool, attempt: Int) {
        Self.childPID.set(0)
        process = nil
        if gotResult { return }
        if stopping { phase = .idle; return }
        // GPU fault (exit 2) or a crash: resume from the last checkpoint, a few times.
        if (status == 2 || crashed) && attempt < 3 {
            Self.log("restart attempt \(attempt + 1) after status \(status)\(crashed ? " (crashed)" : "")")
            launch(resume: true, attempt: attempt + 1)
            return
        }
        phase = .failed(lastError ?? "Training stopped unexpectedly. MurmurBee itself kept running; try again later.")
    }

    // MARK: - Settings

    /// Training settings. Environment overrides (MB_*) exist for experiments (E15); the defaults ship.
    struct Hyper: Sendable {
        var lr = 5e-5, warmup = 60, minLRFraction = 0.1, rank = 8, layers = 16, editWeight = 3, seed: UInt64 = 1  // E15 R2; fixed seed (E15f), 0 = random
        static var current: Hyper {
            let e = ProcessInfo.processInfo.environment
            var h = Hyper()
            if let v = e["MB_LR"].flatMap(Double.init) { h.lr = v }
            if let v = e["MB_WARMUP"].flatMap(Int.init) { h.warmup = v }
            if let v = e["MB_MIN_LR"].flatMap(Double.init) { h.minLRFraction = v }
            if let v = e["MB_RANK"].flatMap(Int.init) { h.rank = v }
            if let v = e["MB_LAYERS"].flatMap(Int.init) { h.layers = v }
            if let v = e["MB_EDIT_WEIGHT"].flatMap(Int.init) { h.editWeight = v }
            if let v = e["MB_SEED"].flatMap(UInt64.init) { h.seed = v }
            return h
        }
        /// Linear warm-up, then cosine decay to minLRFraction × lr.
        func learningRate(step: Int, of total: Int) -> Float {
            if step < warmup { return Float(lr * Double(step + 1) / Double(warmup)) }
            let t = Double(step - warmup) / Double(max(1, total - warmup))
            let floor = lr * minLRFraction
            return Float(floor + (lr - floor) * 0.5 * (1 + cos(.pi * t)))
        }
    }

    /// Deterministic sampling when a seed is set (so experiments compare settings, not luck).
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Data

    struct Example: Sendable {
        let prompt: String, target: String, date: Date
        /// Fair to test on: the target came from you (an edit) or from another app, not from the model being tested.
        let independent: Bool
        /// You corrected this one by hand: the clearest signal of what you want.
        var edited = false
    }

    /// Pairs from history: Wispr imports use your final text (your edit, else what was pasted); MurmurBee's own rows
    /// use what was pasted. Obvious junk (empty, huge, wildly different lengths) is dropped.
    nonisolated static func examples(from rows: [Store.TrainingRow], user: String) -> [Example] {
        let tz = PromptContext()
        return rows.compactMap { r in
            let target = (r.source == "wispr" ? (r.edited ?? r.pasted) : r.pasted)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = r.asr.trimmingCharacters(in: .whitespacesAndNewlines)
            let rw = raw.split(whereSeparator: \.isWhitespace).count, tw = target.split(whereSeparator: \.isWhitespace).count
            guard rw >= 1, tw >= 1, rw <= 220, tw <= 220 else { return nil }
            let ratio = Double(tw) / Double(rw)
            guard ratio > 0.35, ratio < 1.8 else { return nil }
            let type = r.appType.isEmpty
                ? (ContextSnapshot.appTypes[r.bundle]?.1 ?? (r.url.contains("mail.") ? "email" : "general"))
                : r.appType
            var ctx = tz
            ctx.user = user
            ctx.selected = r.selected
            let prompt = PromptV3.userMessage(appName: r.app.isEmpty ? "Unknown" : r.app, appType: type, raw: raw,
                                              vocab: [], before: r.before, ctx: ctx)
            return Example(prompt: prompt, target: target, date: r.date,
                           independent: r.source == "wispr" || r.edited != nil, edited: r.edited != nil)
        }
    }

    // MARK: - The run

    /// Checkpoint state, so a run interrupted by a GPU fault can resume where it stopped.
    struct Progress: Codable { var currentWER: Double; var step: Int; var steps: Int }

    nonisolated static func run(store: Store, user: String, steps stepsOverride: Int? = nil, heldLimit: Int? = nil,
                                install: Bool = true, resume: Bool = false,
                                report: @escaping @Sendable (Phase) -> Void) async throws -> Outcome {
        let started = Date()
        let env = ProcessInfo.processInfo.environment  // MB_STEPS / MB_HELD / MB_NO_INSTALL: test overrides
        let stepsOverride = stepsOverride ?? env["MB_STEPS"].flatMap(Int.init)
        let heldLimit = heldLimit ?? env["MB_HELD"].flatMap(Int.init)
        let install = install && env["MB_NO_INSTALL"] == nil
        let all = examples(from: await store.trainingRows(), user: user).sorted { $0.date < $1.date }
        guard all.count >= 200 else { throw TrainError.notEnoughData(all.count) }
        // Hold out the newest 5% (40–150) of the independent examples: a fair test on dictations the new model
        // never trained on, whose text the current model didn't write itself.
        let independent = all.filter(\.independent)
        let heldCount = min(heldLimit ?? 150, max(min(40, heldLimit ?? 40), independent.count / 20), independent.count)
        let held = Array(independent.suffix(heldCount))
        let cutoff = held.first?.date ?? .distantFuture
        // E15f: the newest independent dictations before the held-out ones pick the best checkpoint, so that choice
        // never sees the gate's test set. They are kept out of training too.
        let before = all.filter { $0.date < cutoff }
        let validation = Array(before.filter(\.independent).suffix(60))
        let valCutoff = validation.first?.date ?? cutoff
        let train = Array(before.filter { $0.date < valCutoff }.suffix(6000))

        let generalDir = ModelStore.directory.appendingPathComponent(generalName)
        guard FileManager.default.fileExists(atPath: generalDir.path) else { throw TrainError.noGeneralModel }
        guard let currentDir = ModelStore.best() else { throw TrainError.noGeneralModel }

        let staging = ModelStore.directory.appendingPathComponent(".personal-training")
        let progressURL = staging.appendingPathComponent("progress.json")
        let checkpointURL = staging.appendingPathComponent("checkpoint.safetensors")
        let optimizerURL = staging.appendingPathComponent("optimizer.safetensors")
        var saved = resume ? (try? JSONDecoder().decode(Progress.self, from: Data(contentsOf: progressURL))) : nil
        if saved != nil && !FileManager.default.fileExists(atPath: checkpointURL.path) { saved?.step = 0 }
        if saved == nil {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        }

        // 1. How well does the model you use now do on the held-out dictations? (Kept across a resume.)
        let currentWER: Double
        if let saved { currentWER = saved.currentWER } else {
            let current = try await loadContainer(currentDir)
            currentWER = try await score(current, held) { report(.checkingCurrent(done: $0, total: held.count)) }
        }

        // 2. Train a LoRA on the general model.
        // E15d: 2,400 steps on a full history beat 1,200 clearly (0.105 vs 0.116 held-out WER).
        let steps = saved?.steps ?? stepsOverride ?? min(2400, max(300, Int(Double(train.count) / 2.5)))
        let startStep = saved?.step ?? 0
        try JSONEncoder().encode(Progress(currentWER: currentWER, step: startStep, steps: steps)).write(to: progressURL)
        let base = try await loadModelContainer(from: generalDir, using: #huggingFaceTokenizerLoader())
        let hyper = Hyper.current
        if hyper.seed != 0 { MLXRandom.seed(hyper.seed) }
        let config = LoRAConfiguration(numLayers: hyper.layers, loraParameters: .init(rank: hyper.rank, scale: 20.0))
        try await base.perform { context in
            let model = context.model
            _ = try LoRAContainer.from(model: model, configuration: config)
            if startStep > 0 { try LoRATrain.loadLoRAWeights(model: model, url: checkpointURL) }
            try trainLoop(model: model, tokenizer: context.tokenizer, examples: train, steps: steps, from: startStep,
                          hyper: hyper, optimizerState: startStep > 0 ? optimizerURL : nil,
                          snapshotAt: Set(snapshotSteps(steps)),
                          snapshot: { step in
                              try LoRATrain.saveLoRAWeights(model: model, url: snapshotURL(staging, step))
                          },
                          checkpoint: { step, optimizer in
                              try LoRATrain.saveLoRAWeights(model: model, url: checkpointURL)
                              try optimizer.save(to: optimizerURL)
                              try JSONEncoder().encode(Progress(currentWER: currentWER, step: step, steps: steps))
                                  .write(to: progressURL)
                          }) { step, loss in
                report(.training(step: step, total: steps, loss: loss))
            }
            model.train(false)
        }
        try JSONEncoder().encode(config).write(to: staging.appendingPathComponent("adapter_config.json"))

        // E15f: one run's final step is a coin flip (0.093–0.127 across seeds), so score the last few snapshots on the
        // validation dictations and keep the best one.
        var bestStep = steps, bestVal = Double.infinity
        for step in snapshotSteps(steps) {
            let dir = staging.appendingPathComponent("snapshot-\(step)")
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: snapshotURL(staging, step), to: dir.appendingPathComponent("adapters.safetensors"))
            try JSONEncoder().encode(config).write(to: dir.appendingPathComponent("adapter_config.json"))
            let wer = try await score(try await loadContainer(generalDir, adapter: dir), validation) { _ in }
            print(String(format: "V %d %.4f", step, wer))
            if wer < bestVal { bestVal = wer; bestStep = step }
            try? FileManager.default.removeItem(at: dir)
        }
        let adapterURL = staging.appendingPathComponent("adapters.safetensors")
        try? FileManager.default.removeItem(at: adapterURL)
        try FileManager.default.copyItem(at: snapshotURL(staging, bestStep), to: adapterURL)
        for step in snapshotSteps(steps) { try? FileManager.default.removeItem(at: snapshotURL(staging, step)) }

        // (Experiments: also score the general model on its own, to measure what personal training adds.)
        if ProcessInfo.processInfo.environment["MB_SCORE_GENERAL"] != nil, currentDir.lastPathComponent != generalName {
            let general = try await loadContainer(generalDir)
            let g = try await score(general, held) { _ in }
            print(String(format: "general model WER %.3f", g))
        }

        // 3. Score the new model on the same held-out dictations.
        let candidate = try await loadContainer(generalDir, adapter: staging)
        let newWER = try await score(candidate, held) { report(.checkingNew(done: $0, total: held.count)) }

        // 4. Keep it only if it's better than what you use now.
        try? FileManager.default.removeItem(at: progressURL)
        try? FileManager.default.removeItem(at: checkpointURL)
        try? FileManager.default.removeItem(at: optimizerURL)
        let installed = install && newWER < currentWER
        if installed {
            let meta: [String: Any] = [
                "prompt": "v3", "rank": 20, "base": generalName, "trained": ISO8601DateFormatter().string(from: Date()),
                "examples": train.count, "heldOut": held.count, "wer": newWER, "currentWer": currentWER,
                "replaced": currentDir.lastPathComponent, "bestStep": bestStep, "seed": hyper.seed,
            ]
            try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted)
                .write(to: staging.appendingPathComponent("localflow.json"))
            try? FileManager.default.removeItem(at: personalDir)
            try FileManager.default.moveItem(at: staging, to: personalDir)
        } else {
            try? FileManager.default.removeItem(at: staging)
        }
        return Outcome(installed: installed, currentWER: currentWER, newWER: newWER, examples: train.count,
                       heldOut: held.count, minutes: Date().timeIntervalSince(started) / 60)
    }

    /// Loads a full model directory, or a base model with a LoRA adapter on top.
    nonisolated static func loadContainer(_ dir: URL, adapter: URL? = nil) async throws -> ModelContainer {
        var baseDir = dir, adapterDir = adapter
        if adapter == nil, let base = baseName(of: dir) {
            baseDir = ModelStore.directory.appendingPathComponent(base)
            adapterDir = dir
        }
        let container = try await loadModelContainer(from: baseDir, using: #huggingFaceTokenizerLoader())
        if let adapterDir {
            let lora = try LoRAContainer.from(directory: adapterDir)
            try await container.perform { context in try lora.load(into: context.model) }
        }
        return container
    }

    /// The base model named in an adapter directory's localflow.json, if it is an adapter.
    nonisolated static func baseName(of dir: URL) -> String? {
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("adapters.safetensors").path),
              let data = try? Data(contentsOf: dir.appendingPathComponent("localflow.json")),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return cfg["base"] as? String
    }

    /// The steps whose weights are kept as candidates: two thirds, five sixths and the end of the run.
    nonisolated static func snapshotSteps(_ steps: Int) -> [Int] {
        Array(Set([steps * 2 / 3, steps * 5 / 6, steps].map { max(1, $0) })).sorted()
    }
    nonisolated static func snapshotURL(_ staging: URL, _ step: Int) -> URL {
        staging.appendingPathComponent("snapshot-\(step).safetensors")
    }

    /// Adam (no bias correction, like MLX's default) whose moment estimates can be saved and restored, so a run that
    /// resumes after a GPU fault continues exactly where it stopped. MLX's own Adam keeps its state private.
    final class ResumableAdam {
        var learningRate: Float
        let b1: Float = 0.9, b2: Float = 0.999, eps: Float = 1e-8
        private var m: [String: MLXArray] = [:], v: [String: MLXArray] = [:]
        init(learningRate: Float) { self.learningRate = learningRate }

        func update(model: Module, gradients: ModuleParameters) {
            let params = Dictionary(model.trainableParameters().flattened(), uniquingKeysWith: { a, _ in a })
            var updated: [(String, MLXArray)] = []
            for (key, g) in gradients.flattened() {
                guard let p = params[key] else { continue }
                let m1 = b1 * (m[key] ?? MLXArray.zeros(like: g)) + (1 - b1) * g
                let v1 = b2 * (v[key] ?? MLXArray.zeros(like: g)) + (1 - b2) * square(g)
                m[key] = m1; v[key] = v1
                updated.append((key, p - learningRate * m1 / (sqrt(v1) + eps)))
            }
            model.update(parameters: ModuleParameters.unflattened(updated))
        }
        var state: [MLXArray] { Array(m.values) + Array(v.values) }
        func save(to url: URL) throws {
            var arrays: [String: MLXArray] = [:]
            for (k, x) in m { arrays["m." + k] = x }
            for (k, x) in v { arrays["v." + k] = x }
            try MLX.save(arrays: arrays, url: url)
        }
        func load(from url: URL) throws {
            for (k, x) in try loadArrays(url: url) {
                if k.hasPrefix("m.") { m[String(k.dropFirst(2))] = x } else if k.hasPrefix("v.") { v[String(k.dropFirst(2))] = x }
            }
        }
    }

    // MARK: - Training loop (answer-only loss, like mlx_lm's mask_prompt)

    nonisolated private static func trainLoop(model: any LanguageModel, tokenizer: any MLXLMCommon.Tokenizer, examples: [Example],
                                              steps: Int, from startStep: Int = 0, hyper: Hyper,
                                              optimizerState: URL? = nil, snapshotAt: Set<Int> = [],
                                              snapshot: (Int) throws -> Void = { _ in },
                                              checkpoint: (Int, ResumableAdam) throws -> Void = { _, _ in },
                                              report: (Int, Float?) -> Void) throws {
        // Hand-edited examples can be sampled more often (editWeight copies each).
        let weighted = examples.flatMap { e in Array(repeating: e, count: e.edited ? max(1, hyper.editWeight) : 1) }
        let encoded: [(tokens: [Int], promptLength: Int)] = weighted.compactMap { e in
            guard let prompt = try? tokenizer.applyChatTemplate(
                messages: [["role": "system", "content": Cleaner.system], ["role": "user", "content": e.prompt]],
                tools: nil, additionalContext: ["enable_thinking": false]) else { return nil }
            let answer = tokenizer.encode(text: e.target + "<|im_end|>", addSpecialTokens: false)
            let all = prompt + answer
            return all.count <= 768 ? (all, prompt.count) : nil  // long sequences risk the GPU watchdog
        }
        guard !encoded.isEmpty else { throw TrainError.notEnoughData(0) }

        let optimizer = ResumableAdam(learningRate: hyper.learningRate(step: 0, of: steps))
        if let optimizerState, FileManager.default.fileExists(atPath: optimizerState.path) {
            try optimizer.load(from: optimizerState)
        }
        var rng = SplitMix(state: hyper.seed == 0 ? UInt64.random(in: 1...UInt64.max) : hyper.seed)
        let lossAndGrad = valueAndGrad(model: model) { model, arrays in
            let (inputs, targets, mask) = (arrays[0], arrays[1], arrays[2])
            let logits = (model as! any LanguageModel)(inputs, cache: nil).asType(.float32)
            let ce = (crossEntropy(logits: logits, targets: targets) * mask).sum() / mask.sum()
            return [ce]
        }
        model.train(true)
        var recent: [Float] = []
        for _ in 0..<startStep { _ = rng.next() }  // keep the sampling sequence when resuming
        for step in startStep..<steps {
            while pause.get() && !cancel.get() { Thread.sleep(forTimeInterval: 0.2) }
            if cancel.get() { throw CancellationError() }
            optimizer.learningRate = hyper.learningRate(step: step, of: steps)
            let (tokens, promptLength) = encoded[Int.random(in: 0..<encoded.count, using: &rng)]
            let inputs = MLXArray(tokens.dropLast().map(Int32.init)).reshaped(1, -1)
            let targets = MLXArray(tokens.dropFirst().map(Int32.init)).reshaped(1, -1)
            // Position i predicts token i+1: learn only the answer (positions from promptLength-1 on).
            let mask = (MLXArray(0..<Int32(tokens.count - 1)) .>= Int32(promptLength - 1)).asType(.float32)
                .reshaped(1, -1)
            let (values, grads) = lossAndGrad(model, [inputs, targets, mask])
            optimizer.update(model: model, gradients: grads)
            // MLX eval materialises the arrays (it is not code evaluation). A GPU fault (e.g. macOS's GPU watchdog)
            // becomes a thrown error here instead of crashing; the helper exits and the app resumes from a checkpoint.
            do { try withError { eval(model, optimizer.state, values[0]) } } catch { throw TrainError.gpu(step) }
            recent.append(values[0].item(Float.self))
            if snapshotAt.contains(step + 1) { try snapshot(step + 1) }
            if (step + 1) % 200 == 0 { try checkpoint(step + 1, optimizer) }
            if (step + 1) % 10 == 0 || step == startStep {
                report(step + 1, recent.isEmpty ? nil : recent.reduce(0, +) / Float(recent.count))
                recent.removeAll()
            }
        }
    }

    // MARK: - Scoring

    /// Mean word error rate of a model's output against your final text on the held-out examples.
    nonisolated private static func score(_ container: ModelContainer, _ examples: [Example],
                                          progress: (Int) -> Void) async throws -> Double {
        var total = 0.0
        for (i, e) in examples.enumerated() {
            while pause.get() && !cancel.get() { try await Task.sleep(for: .milliseconds(200)) }
            if cancel.get() { throw CancellationError() }
            let words = e.prompt.split(whereSeparator: \.isWhitespace).count
            let input = try await container.prepare(input: UserInput(
                chat: [.system(Cleaner.system), .user(e.prompt)], additionalContext: ["enable_thinking": false]))
            var out = ""
            for await event in try await container.generate(
                input: input, parameters: GenerateParameters(maxTokens: min(600, words * 2 + 24), temperature: 0)) {
                if let chunk = event.chunk { out += chunk }
                if Cleaner.isLooping(out) { break }
            }
            total += wer(reference: e.target, hypothesis: out)
            progress(i + 1)
        }
        return total / Double(max(1, examples.count))
    }

    nonisolated static func wer(reference: String, hypothesis: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = r[i - 1] == h[j - 1] ? prev[j - 1] : 1 + min(prev[j - 1], prev[j], cur[j - 1])
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }

    enum TrainError: LocalizedError {
        case notEnoughData(Int), noGeneralModel, gpu(Int)
        var errorDescription: String? {
            switch self {
            case .notEnoughData(let n): "Not enough history yet (\(n) usable dictations; 200 needed)."
            case .noGeneralModel: "The general cleanup model isn't installed yet."
            case .gpu(let step): "The GPU stopped responding at step \(step)."
            }
        }
    }
}

/// A thread-safe integer.
final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
}

/// Splits a byte stream into lines (helper output).
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var out: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            out.append(String(decoding: data[data.startIndex..<nl], as: UTF8.self))
            data.removeSubrange(data.startIndex...nl)
        }
        return out
    }
}

/// A thread-safe boolean.
final class Flag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

extension Notification.Name {
    static let personalModelInstalled = Notification.Name("MurmurBeePersonalModelInstalled")
}
