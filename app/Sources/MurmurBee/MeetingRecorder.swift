@preconcurrency import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio

/// Records a call into two 16 kHz mono files in `dir`: mic.wav (you) and call.wav (everything the Mac plays, through
/// a Core Audio process tap, which is everyone else). Both are written against one clock, with silence filling any
/// gap, so they stay aligned to the sample even if a device changes mid-call.
final class MeetingRecorder: @unchecked Sendable {
    static let rate = 16_000.0

    /// One channel's file. Written from its audio thread, read by the once-a-second status check.
    final class Track: @unchecked Sendable {
        private let lock = NSLock()
        private var file: AVAudioFile?
        private var converter: AVAudioConverter?
        private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        private let start: Double
        private var frames: Int64 = 0
        private var lastSound: Date?

        init(_ url: URL, start: Double) throws {
            self.start = start
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            guard let file, buffer.frameLength > 0 else { return }
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
                converter?.downmix = true
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * rate / buffer.format.sampleRate) + 32
            guard let converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }
            if hostTime != 0 {
                let due = Int64((AVAudioTime.seconds(forHostTime: hostTime) - start) * rate)
                if due - frames > Int64(rate / 10) { pad(file, Int(due - frames)) }
            }
            try? file.write(from: out)
            frames += Int64(out.frameLength)
            // Sound means a level speech would have (above -50 dBFS), not just any non-zero sample: some apps keep
            // playing near-silence, which would otherwise look like a call that never ends.
            var sum: Float = 0
            for i in 0..<Int(out.frameLength) { sum += samples[i] * samples[i] }
            if (sum / Float(out.frameLength)).squareRoot() > 0.003 { lastSound = Date() }
        }

        private func pad(_ file: AVAudioFile, _ count: Int) {
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)) else { return }
            var left = count
            while left > 0 {
                silence.frameLength = AVAudioFrameCount(min(left, Int(rate)))
                memset(silence.floatChannelData![0], 0, Int(silence.frameLength) * MemoryLayout<Float>.size)
                try? file.write(from: silence)
                left -= Int(silence.frameLength)
                frames += Int64(silence.frameLength)
            }
        }

        var heard: Date? { lock.lock(); defer { lock.unlock() }; return lastSound }

        /// Closing the file finalises its WAV header.
        func close() { lock.lock(); file = nil; lock.unlock() }
    }

    private var mic: Track?
    private var call: Track?
    private var engine: AVAudioEngine?
    private var micDevice: AudioDeviceID?
    private var observer: NSObjectProtocol?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var output = AudioObjectID(kAudioObjectUnknown)

    /// When the call audio last had sound in it; nil until it first does. macOS gives silence, not an error,
    /// when System Audio Recording isn't allowed, so this is also how a missing permission shows up.
    var callHeard: Date? { call?.heard }
    /// When the mic last picked up sound at speaking level.
    var micHeard: Date? { mic?.heard }

    /// `device` nil = system default input.
    func start(in dir: URL, device: AudioDeviceID?) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t0 = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        call = try Track(dir.appendingPathComponent("call.wav"), start: t0)
        mic = try Track(dir.appendingPathComponent("mic.wav"), start: t0)
        micDevice = device
        try startMic()
        do { try startCall() } catch { NSLog("MurmurBee: call audio unavailable: \(error)") }  // the mic alone still gives notes
    }

    private func startMic() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if var id = micDevice ?? AudioDevices.systemDefaultInput(), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let track = mic
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, time in
            track?.write(buffer, hostTime: time.isHostTimeValid ? time.hostTime : 0)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        // Plugging in a headset or changing the default input stops the engine; pick the mic up again.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in self?.restartMic() }
    }

    private func stopMic() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func restartMic() {
        guard mic != nil else { return }
        stopMic()
        do { try startMic() } catch { NSLog("MurmurBee: microphone lost: \(error)") }
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            throw NSError(domain: "MeetingRecorder", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "\(what) failed: \(status)"])
        }
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read property \(selector)")
        return value
    }

    private static func defaultOutput() throws -> AudioObjectID {
        try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0))
    }

    private func startCall() throws {
        // Every process's output. MurmurBee's own chimes are in there too, but they're short and aren't speech.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        var asbd = try Self.property(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw NSError(domain: "MeetingRecorder", code: -1) }

        output = try Self.defaultOutput()
        let outputUID = try Self.property(output, kAudioDevicePropertyDeviceUID, "" as CFString) as String
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MurmurBee call tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        let track = call
        let queue = DispatchQueue(label: "murmurbee.call-tap", qos: .userInteractive)
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            track?.write(buffer, hostTime: inputTime.pointee.mHostTime)
        }, "create IO proc")
        try Self.check(AudioDeviceStart(aggregateID, procID), "start call tap")
    }

    private func stopCall() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// The tap follows one output device, so a change (headphones, a monitor unplugged) needs a new one.
    func followOutput() {
        guard call != nil, let now = try? Self.defaultOutput(), now != output else { return }
        stopCall()
        do { try startCall() } catch { NSLog("MurmurBee: call audio lost: \(error)") }
    }

    func stop() {
        stopMic()
        stopCall()
        mic?.close()
        call?.close()
        mic = nil
        call = nil
    }
}

/// Who else is using a microphone right now, which is how a call shows up whatever app or website it's in.
enum CallDetector {
    struct App: Equatable, Sendable {
        let bundle: String
        let name: String
    }

    /// Mic users that aren't calls: Apple's own services, and dictation apps (a long dictation isn't a meeting).
    private static let appleCalls = ["com.apple.FaceTime", "com.apple.avconferenced", "com.apple.WebKit", "com.apple.Safari"]
    private static let dictationApps = ["com.electron.wispr-flow", "com.superduper.superwhisper", "com.goodsnooze.MacWhisper"]

    static func appsUsingMicrophone() -> [App] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return ids.compactMap { id -> App? in
            var running: UInt32 = 0
            guard read(id, kAudioProcessPropertyIsRunningInput, &running), running != 0 else { return nil }
            var pid: pid_t = 0
            guard read(id, kAudioProcessPropertyPID, &pid), pid != me else { return nil }
            var value: Unmanaged<CFString>?
            let bundle = read(id, kAudioProcessPropertyBundleID, &value) ? (value?.takeRetainedValue() as String? ?? "") : ""
            if bundle.hasPrefix("com.apple."), !appleCalls.contains(where: bundle.hasPrefix) { return nil }
            if dictationApps.contains(bundle) { return nil }
            return App(bundle: bundle, name: name(pid: pid, bundle: bundle))
        }
    }

    private static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
    }

    /// Browsers capture through a helper process, so its name loses " Helper (Renderer)" and the like.
    private static func name(pid: pid_t, bundle: String) -> String {
        if bundle.hasPrefix("com.apple.WebKit") { return "Safari" }
        if bundle == "com.apple.avconferenced" { return "FaceTime" }
        if bundle == "us.zoom.xos" { return "Zoom" }
        let full = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        if !full.isEmpty { return full.components(separatedBy: " Helper")[0] }
        // A helper process often isn't a running app of its own: name it after the app its bundle id belongs to
        // ("com.google.Chrome.helper" is Google Chrome).
        var id = bundle
        while !id.isEmpty {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            }
            guard let dot = id.lastIndex(of: ".") else { break }
            id = String(id[..<dot])
        }
        return ""
    }
}
