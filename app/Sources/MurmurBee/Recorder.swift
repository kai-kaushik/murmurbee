@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Synchronization
import OSLog

/// Records only during dictation. Hardware work never blocks the app's main thread.
final class Recorder: Sendable {
    static let sampleRate = 16_000.0
    static let maxSeconds = 600.0
    enum Status: Equatable { case idle, starting, recording, failed(String) }

    private struct Capture {
        var generation = UUID()
        var active = false
        var samples: [Float] = []
        var health: CaptureHealth?
        var failure: String?
    }
    private struct Hardware {
        var engine = AVAudioEngine()
        var device: AudioDeviceID?
        var generation = UUID()
        var observer: NSObjectProtocol?
        var watchdog: DispatchSourceTimer?
        var tapped = false
        var recoveries = 0
        var lastRecovery = 0.0
        var announcedReady = false
    }
    private let capture = Mutex(Capture())
    private let hardware = Mutex(Hardware())
    private let level = Atomic<Float>(0)
    private let queue = DispatchQueue(label: "com.murmurbee.capture", qos: .userInitiated)
    private static let logger = Logger(subsystem: "com.murmurbee.app", category: "Recorder")
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var count: Int { capture.withLock { $0.samples.count } }
    var currentLevel: Float { level.load(ordering: .relaxed) }
    var status: Status {
        capture.withLock { state in
            if let failure = state.failure { return .failed(failure) }
            guard state.active, let health = state.health else { return .idle }
            switch health.status(at: Self.now) {
            case .starting: return .starting
            case .recording: return .recording
            case .failed: return .failed("Microphone stopped delivering audio. Release the key and try again.")
            }
        }
    }

    func snapshot(from start: Int, to end: Int) -> [Float] {
        capture.withLock { state in
            let lo = min(max(0, start), state.samples.count)
            let hi = max(lo, min(end, state.samples.count))
            return Array(state.samples[lo..<hi])
        }
    }

    /// Starts asynchronously; `status` becomes recording only after sustained audio arrives.
    func start(device: AudioDeviceID? = nil) throws {
        try requestStart { device }
    }

    func start(selection: String) throws {
        try requestStart { AudioDevices.resolve(selection) }
    }

    private func requestStart(_ resolve: @escaping @Sendable () -> AudioDeviceID?) throws {
        let generation = UUID()
        capture.withLock { state in
            state.generation = generation
            state.active = true
            state.failure = nil
            state.samples.removeAll(keepingCapacity: true)
            state.health = CaptureHealth(startedAt: Self.now)
        }
        level.store(0, ordering: .relaxed)
        Self.logger.info("Capture requested")
        queue.async { [self] in
            guard isActive(generation) else { return }
            startHardware(device: resolve(), generation: generation)
        }
    }

    private func isActive(_ generation: UUID) -> Bool {
        capture.withLock { $0.active && $0.generation == generation }
    }

    private func startHardware(device: AudioDeviceID?, generation: UUID) {
        guard isActive(generation) else { return }
        hardware.withLock { state in
            stopHardware(&state)
            state.generation = generation
            state.recoveries = 0
            state.announcedReady = false
            do {
                guard var selected = device ?? AudioDevices.systemDefaultInput() else {
                    throw NSError(domain: "Recorder", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "No microphone is available"])
                }
                // Keep a stopped graph for the same route; setting CurrentDevice again triggers reconfiguration.
                if state.device != selected {
                    state.engine = AVAudioEngine()
                    guard let unit = state.engine.inputNode.audioUnit else {
                        throw NSError(domain: "Recorder", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Microphone audio unit is unavailable"])
                    }
                    var current = AudioDeviceID(0)
                    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
                    let read = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                    kAudioUnitScope_Global, 0, &current, &size)
                    if read != noErr || current != selected {
                        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                          kAudioUnitScope_Global, 0, &selected, size)
                        guard result == noErr else {
                            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
                        }
                    }
                    state.device = selected
                }
                try installTap(&state, generation: generation)
                state.observer = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: state.engine, queue: nil
                ) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { [self] in
                        capture.withLock { current in
                            guard current.active, current.generation == generation else { return }
                            current.health?.configurationChanged()
                        }
                    }
                }
                state.engine.prepare()
                try state.engine.start()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
                timer.setEventHandler { [weak self] in self?.checkCapture(generation) }
                state.watchdog = timer
                timer.resume()
                Self.logger.info("Audio engine start returned")
            } catch {
                fail(generation, error.localizedDescription)
                stopHardware(&state)
            }
        }
    }

    private func installTap(_ state: inout Hardware, generation: UUID) throws {
        let input = state.engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                        channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw NSError(domain: "Recorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone has no usable input format"])
        }
        let ratio = Self.sampleRate / format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            let rms = sqrt(chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count))
            capture.withLock { current in
                guard current.active, current.generation == generation else { return }
                if current.health?.firstBufferAt == nil {
                    let elapsed = (Self.now - (current.health?.startedAt ?? Self.now)) * 1000
                    Self.logger.info("First audio buffer after \(elapsed, privacy: .public) ms")
                }
                current.health?.receive(frames: chunk.count, at: Self.now)
                let remaining = max(0, Int(Self.maxSeconds * Self.sampleRate) - current.samples.count)
                current.samples.append(contentsOf: chunk.prefix(remaining))
                level.store(rms, ordering: .relaxed)
            }
        }
        state.tapped = true
    }

    private func checkCapture(_ generation: UUID) {
        hardware.withLock { state in
            guard state.generation == generation else { return }
            guard isActive(generation) else { stopHardware(&state); return }
            let now = Self.now
            let health = capture.withLock { $0.health }
            guard let health else { return }
            switch health.status(at: now) {
            case .failed:
                fail(generation, "Microphone did not deliver continuous audio. Release the key and try again.")
                stopHardware(&state)
            case .recording:
                state.recoveries = 0
                if !state.announcedReady {
                    state.announcedReady = true
                    let elapsed = (now - health.startedAt) * 1000
                    Self.logger.info("Continuous audio ready after \(elapsed, privacy: .public) ms")
                }
            case .starting:
                state.announcedReady = false
                let lastAudio = health.lastBufferAt ?? health.startedAt
                guard (!state.engine.isRunning || now - lastAudio > 0.8),
                      now - state.lastRecovery > 0.6 else { return }
                guard state.recoveries < 3 else { return } // the arrival deadline still terminates a stalled start
                state.recoveries += 1
                state.lastRecovery = now
                if state.tapped { state.engine.inputNode.removeTap(onBus: 0); state.tapped = false }
                state.engine.stop()
                do {
                    capture.withLock { $0.health?.configurationChanged() }
                    try installTap(&state, generation: generation)
                    state.engine.prepare()
                    try state.engine.start()
                    let attempt = state.recoveries
                    Self.logger.info("Retrying microphone capture, attempt \(attempt)")
                } catch {
                    Self.logger.error("Microphone retry failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func fail(_ generation: UUID, _ message: String) {
        capture.withLock { state in
            guard state.generation == generation, state.active else { return }
            state.failure = message
            state.active = false
            Self.logger.error("Capture failed: \(message, privacy: .public)")
        }
    }

    private func stopHardware(_ state: inout Hardware) {
        state.watchdog?.cancel()
        state.watchdog = nil
        if let observer = state.observer { NotificationCenter.default.removeObserver(observer) }
        state.observer = nil
        if state.tapped { state.engine.inputNode.removeTap(onBus: 0); state.tapped = false }
        state.engine.stop()
    }

    func stop() {
        let generation = capture.withLock { state in
            state.active = false
            state.failure = nil
            return state.generation
        }
        level.store(0, ordering: .relaxed)
        queue.async { [self] in
            hardware.withLock { state in
                guard state.generation == generation else { return }
                stopHardware(&state)
            }
        }
    }
}
