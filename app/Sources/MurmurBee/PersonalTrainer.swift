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

    func start() {
        guard let store, !running else { return }
        Self.cancel.set(false)
        phase = .preparing
        let user = userName
        Task.detached(priority: .utility) {
            do {
                let outcome = try await Self.run(store: store, user: user) { p in
                    Task { @MainActor in PersonalTrainer.shared.phase = p }
                }
                await MainActor.run {
                    PersonalTrainer.shared.phase = .finished(outcome)
                    if outcome.installed { NotificationCenter.default.post(name: .personalModelInstalled, object: nil) }
                }
            } catch is CancellationError {
                await MainActor.run { PersonalTrainer.shared.phase = .idle }
            } catch {
                await MainActor.run { PersonalTrainer.shared.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func stop() { Self.cancel.set(true) }

    // MARK: - Data

    struct Example: Sendable {
        let prompt: String, target: String, date: Date
        /// Fair to test on: the target came from you (an edit) or from another app, not from the model being tested.
        let independent: Bool
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
                           independent: r.source == "wispr" || r.edited != nil)
        }
    }

    // MARK: - The run

    nonisolated static func run(store: Store, user: String, steps stepsOverride: Int? = nil, heldLimit: Int? = nil,
                                install: Bool = true,
                                report: @escaping @Sendable (Phase) -> Void) async throws -> Outcome {
        let started = Date()
        let all = examples(from: await store.trainingRows(), user: user).sorted { $0.date < $1.date }
        guard all.count >= 200 else { throw TrainError.notEnoughData(all.count) }
        // Hold out the newest 5% (40–150) of the independent examples: a fair test on dictations the new model
        // never trained on, whose text the current model didn't write itself.
        let independent = all.filter(\.independent)
        let heldCount = min(heldLimit ?? 150, max(min(40, heldLimit ?? 40), independent.count / 20), independent.count)
        let held = Array(independent.suffix(heldCount))
        let cutoff = held.first?.date ?? .distantFuture
        let train = Array(all.filter { $0.date < cutoff }.suffix(6000))

        let generalDir = ModelStore.directory.appendingPathComponent(generalName)
        guard FileManager.default.fileExists(atPath: generalDir.path) else { throw TrainError.noGeneralModel }
        guard let currentDir = ModelStore.best() else { throw TrainError.noGeneralModel }

        // 1. How well does the model you use now do on the held-out dictations?
        let current = try await loadContainer(currentDir)
        let currentWER = try await score(current, held) { report(.checkingCurrent(done: $0, total: held.count)) }

        // 2. Train a LoRA on the general model.
        let steps = stepsOverride ?? min(1200, max(300, train.count / 4))
        let staging = ModelStore.directory.appendingPathComponent(".personal-training")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let base = try await loadModelContainer(from: generalDir, using: #huggingFaceTokenizerLoader())
        let config = LoRAConfiguration(numLayers: 16, loraParameters: .init(rank: 8, scale: 20.0))
        try await base.perform { context in
            let model = context.model
            _ = try LoRAContainer.from(model: model, configuration: config)
            try trainLoop(model: model, tokenizer: context.tokenizer, examples: train, steps: steps) { step, loss in
                report(.training(step: step, total: steps, loss: loss))
            }
            model.train(false)
            try LoRATrain.saveLoRAWeights(model: model, url: staging.appendingPathComponent("adapters.safetensors"))
        }
        try JSONEncoder().encode(config).write(to: staging.appendingPathComponent("adapter_config.json"))

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
        let installed = install && newWER < currentWER
        if installed {
            let meta: [String: Any] = [
                "prompt": "v3", "rank": 20, "base": generalName, "trained": ISO8601DateFormatter().string(from: Date()),
                "examples": train.count, "heldOut": held.count, "wer": newWER, "currentWer": currentWER,
                "replaced": currentDir.lastPathComponent,
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

    // MARK: - Training loop (answer-only loss, like mlx_lm's mask_prompt)

    nonisolated private static func trainLoop(model: any LanguageModel, tokenizer: any MLXLMCommon.Tokenizer, examples: [Example],
                                              steps: Int, report: (Int, Float?) -> Void) throws {
        let encoded: [(tokens: [Int], promptLength: Int)] = examples.compactMap { e in
            guard let prompt = try? tokenizer.applyChatTemplate(
                messages: [["role": "system", "content": Cleaner.system], ["role": "user", "content": e.prompt]],
                tools: nil, additionalContext: ["enable_thinking": false]) else { return nil }
            let answer = tokenizer.encode(text: e.target + "<|im_end|>", addSpecialTokens: false)
            let all = prompt + answer
            return all.count <= 1024 ? (all, prompt.count) : nil
        }
        guard !encoded.isEmpty else { throw TrainError.notEnoughData(0) }

        let optimizer = Adam(learningRate: Float(ProcessInfo.processInfo.environment["MB_LR"].flatMap(Double.init) ?? 2e-5))
        let lossAndGrad = valueAndGrad(model: model) { model, arrays in
            let (inputs, targets, mask) = (arrays[0], arrays[1], arrays[2])
            let logits = (model as! any LanguageModel)(inputs, cache: nil).asType(.float32)
            let ce = (crossEntropy(logits: logits, targets: targets) * mask).sum() / mask.sum()
            return [ce]
        }
        model.train(true)
        var recent: [Float] = []
        for step in 0..<steps {
            while pause.get() && !cancel.get() { Thread.sleep(forTimeInterval: 0.2) }
            if cancel.get() { throw CancellationError() }
            let (tokens, promptLength) = encoded[Int.random(in: 0..<encoded.count)]
            let inputs = MLXArray(tokens.dropLast().map(Int32.init)).reshaped(1, -1)
            let targets = MLXArray(tokens.dropFirst().map(Int32.init)).reshaped(1, -1)
            // Position i predicts token i+1: learn only the answer (positions from promptLength-1 on).
            let mask = (MLXArray(0..<Int32(tokens.count - 1)) .>= Int32(promptLength - 1)).asType(.float32)
                .reshaped(1, -1)
            let (values, grads) = lossAndGrad(model, [inputs, targets, mask])
            optimizer.update(model: model, gradients: grads)
            eval(model, optimizer, values[0])  // MLX eval: materialises the arrays (not code evaluation)
            recent.append(values[0].item(Float.self))
            if (step + 1) % 10 == 0 || step == 0 {
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
        case notEnoughData(Int), noGeneralModel
        var errorDescription: String? {
            switch self {
            case .notEnoughData(let n): "Not enough history yet (\(n) usable dictations; 200 needed)."
            case .noGeneralModel: "The general cleanup model isn't installed yet."
            }
        }
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
