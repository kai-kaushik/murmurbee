@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Synchronization

/// Captures the default microphone as 16 kHz mono Float samples into a growing buffer.
/// The engine only runs while a dictation is in progress, so the mic indicator is off otherwise.
final class Recorder: Sendable {
    static let sampleRate = 16_000.0
    static let maxSeconds = 600.0  // hard cap: no runaway recordings

    /// Shared with the audio thread by reference.
    private final class Buffer: Sendable {
        let samples = Mutex<[Float]>([])
        let level = Atomic<Float>(0)
    }

    private let engine = Mutex(AVAudioEngine())
    private let buffer = Buffer()

    var count: Int { buffer.samples.withLock { $0.count } }
    var currentLevel: Float { buffer.level.load(ordering: .relaxed) }

    func snapshot(from start: Int, to end: Int) -> [Float] {
        buffer.samples.withLock { s in Array(s[max(0, start)..<min(end, s.count)]) }
    }

    /// `device` nil = system default input.
    func start(device: AudioDeviceID? = nil) throws {
        buffer.samples.withLock { $0.removeAll(keepingCapacity: true) }
        try engine.withLock { engine in
            let input = engine.inputNode
            if var id = device ?? AudioDevices.systemDefaultInput(), let unit = input.audioUnit {
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            let inFormat = input.outputFormat(forBus: 0)
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio converter"])
            }
            let ratio = Self.sampleRate / inFormat.sampleRate
            input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [buf = self.buffer] buffer, _ in
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
                guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
                var fed = false
                var error: NSError?
                converter.convert(to: out, error: &error) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                guard error == nil, let ch = out.floatChannelData?[0] else { return }
                let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
                var sum: Float = 0
                for x in chunk { sum += x * x }
                buf.level.store(sqrt(sum / Float(max(chunk.count, 1))), ordering: .relaxed)
                buf.samples.withLock { s in
                    if Double(s.count) < Self.maxSeconds * Self.sampleRate { s.append(contentsOf: chunk) }
                }
            }
            engine.prepare()
            try engine.start()
        }
    }

    func stop() {
        engine.withLock { engine in
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        buffer.level.store(0, ordering: .relaxed)
    }
}
