import Foundation
import CoreAudio

@main
struct CaptureHealthTests {
    static func main() {
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            if condition() { print("PASS: \(label)") }
            else { print("FAIL: \(label)"); failures += 1 }
        }
        var health = CaptureHealth(startedAt: 0)
        check(health.status(at: 0.1) == .starting, "an engine with no audio is not ready")
        health.receive(frames: 0, at: 0.2)
        check(health.firstBufferAt == nil, "empty callbacks do not count as captured audio")
        health.receive(frames: 4800, at: 0.3)
        check(health.status(at: 0.4) == .starting, "a brief startup burst does not announce readiness")
        health.receive(frames: 4800, at: 0.6)
        check(health.status(at: 0.6) == .recording, "sustained audio becomes ready")
        check(health.status(at: 1.4) == .starting, "stalled buffers revoke readiness even if the engine runs")
        check(health.status(at: 4.7) == .failed, "a sustained stall reaches a bounded failure")
        check(CaptureHealth(startedAt: 0).status(at: 5.1) == .failed, "a microphone that never delivers audio times out")
        health.configurationChanged()
        check(health.status(at: 0.7) == .starting, "route changes revoke readiness")
        health.receive(frames: 4800, at: 0.8)
        health.receive(frames: 4800, at: 1.1)
        check(health.status(at: 1.1) == .recording, "capture can become ready after reconfiguration")
        let builtIn = AudioDevices.Device(id: 1, uid: "built-in", name: "Built-in", transport: kAudioDeviceTransportTypeBuiltIn)
        let bluetooth = AudioDevices.Device(id: 2, uid: "bluetooth", name: "Bluetooth", transport: kAudioDeviceTransportTypeBluetooth)
        let usb = AudioDevices.Device(id: 3, uid: "usb", name: "USB", transport: kAudioDeviceTransportTypeUSB)
        let devices = [builtIn, bluetooth, usb]
        check(AudioDevices.resolve("auto", inputs: devices, defaultInput: 2) == 1,
              "Automatic prefers built-in input when the default is Bluetooth")
        check(AudioDevices.resolve("auto", inputs: devices, defaultInput: 3) == nil,
              "Automatic follows a USB default")
        check(AudioDevices.resolve("auto", inputs: [bluetooth], defaultInput: 2) == nil,
              "Automatic falls back to the default without a built-in mic")
        check(AudioDevices.resolve("default", inputs: devices, defaultInput: 2) == nil,
              "System default does not override the selected system device")
        check(AudioDevices.resolve("usb", inputs: devices, defaultInput: 2) == 3,
              "An explicitly selected microphone resolves by UID")
        check(AudioDevices.resolve("removed-device", inputs: devices, defaultInput: 2) == nil,
              "A disconnected selected microphone falls back to the system default")
        exit(failures == 0 ? 0 : 1)
    }
}
