import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// meetbench record <dir>   records a real call for M06 until Ctrl-C:
//   mic.wav   the default input device (you)
//   call.wav  everything the Mac plays, through a Core Audio process tap (everyone else)
//   meta.json start host times of both streams, so they can be aligned to the sample
// Prints both levels every 5 s so a silent channel (a missing permission) shows up at once.

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw NSError(domain: "record", code: Int(status),
                                               userInfo: [NSLocalizedDescriptionKey: "\(what) failed: \(status)"]) }
}

private func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read property \(selector)")
    return value
}

/// Running RMS and first-buffer host time for one stream; touched from its audio thread and the status timer.
private final class Meter {
    private let lock = NSLock()
    private var sum = 0.0, count = 0
    private(set) var firstHostTime: UInt64 = 0
    private(set) var frames: Int64 = 0

    func add(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let data = buffer.floatChannelData else { return }
        let channels = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let n = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        var s = 0.0
        for c in 0..<channels { for i in 0..<n { let x = Double(data[c][i]); s += x * x } }
        lock.lock()
        if firstHostTime == 0 { firstHostTime = hostTime }
        sum += s; count += n * channels; frames += Int64(buffer.frameLength)
        lock.unlock()
    }

    /// dBFS since the last call.
    func take() -> Double {
        lock.lock(); defer { sum = 0; count = 0; lock.unlock() }
        return count == 0 ? -.infinity : 10 * log10(max(sum / Double(count), 1e-12))
    }
}

final class CallRecorder {
    private let dir: URL
    private let engine = AVAudioEngine()
    private var micFile: AVAudioFile?
    private var callFile: AVAudioFile?
    private let micMeter = Meter(), callMeter = Meter()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var callRate = 0.0, micRate = 0.0
    private let started = Date()

    init(dir: URL) { self.dir = dir }

    func start() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try startCall()
        try startMic()
    }

    private func startMic() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        micRate = format.sampleRate
        let file = try AVAudioFile(forWriting: dir.appendingPathComponent("mic.wav"), settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        micFile = file
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [micMeter] buffer, time in
            try? file.write(from: buffer)
            micMeter.add(buffer, hostTime: time.hostTime)
        }
        try engine.start()
    }

    private func startCall() throws {
        // Tap every process's output (nothing is excluded; this tool plays no audio itself).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        var asbd = try property(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw NSError(domain: "record", code: -1) }
        callRate = format.sampleRate

        let output = try property(AudioObjectID(kAudioObjectSystemObject),
                                  kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0))
        let outputUID = try property(output, kAudioDevicePropertyDeviceUID, "" as CFString) as String
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetBench call tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        let file = try AVAudioFile(forWriting: dir.appendingPathComponent("call.wav"), settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        callFile = file
        let queue = DispatchQueue(label: "call-tap", qos: .userInteractive)
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [callMeter] _, input, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            try? file.write(from: buffer)
            callMeter.add(buffer, hostTime: inputTime.pointee.mHostTime)
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start call tap")
    }

    func status() -> String {
        let t = Int(Date().timeIntervalSince(started))
        let level = { (db: Double) in db.isFinite ? String(format: "%5.0f dB", db) : "silent" }
        return String(format: "%02d:%02d  mic %@  call %@", t / 60, t % 60, level(micMeter.take()), level(callMeter.take()))
    }

    func stop() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        micFile = nil  // closing the files finalises the WAV headers
        callFile = nil
        let meta: [String: Any] = [
            "mic": ["file": "mic.wav", "rate": micRate, "frames": micMeter.frames,
                    "first_host_time_s": AVAudioTime.seconds(forHostTime: micMeter.firstHostTime)],
            "call": ["file": "call.wav", "rate": callRate, "frames": callMeter.frames,
                     "first_host_time_s": AVAudioTime.seconds(forHostTime: callMeter.firstHostTime)],
            "started": ISO8601DateFormatter().string(from: started),
        ]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("meta.json"))
    }
}

func record(to dir: URL) async throws {
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
        print("Microphone access was refused. Allow it in System Settings > Privacy & Security > Microphone.")
        return
    }
    let recorder = CallRecorder(dir: dir)
    try recorder.start()
    print("Recording to \(dir.path). Press Ctrl-C to stop.")
    print("If call stays silent while people talk, allow System Audio Recording for this terminal app in "
          + "System Settings > Privacy & Security > Screen & System Audio Recording, then start again.")

    signal(SIGINT, SIG_IGN)
    let stopSignal = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 5, repeating: 5)
    timer.setEventHandler { print(recorder.status()) }
    timer.resume()
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        stopSignal.setEventHandler {
            timer.cancel()
            do { try recorder.stop(); print("\nSaved mic.wav, call.wav and meta.json in \(dir.path)") }
            catch { print("\nStopping failed: \(error)") }
            done.resume()
        }
        stopSignal.resume()
    }
}
