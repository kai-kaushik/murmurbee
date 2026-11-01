import AppKit
import AVFoundation
import Foundation
import CoreAudio
struct CaptureComparison {
 static let url = URL(fileURLWithPath: "/tmp/murmurbee-startup-probe.log")
 static func log(_ text: String) {
  let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  try? (old + text + "\n").write(to: url, atomically: true, encoding: .utf8)
 }
 @MainActor static func run() async {
  try? "".write(to: url, atomically: true, encoding: .utf8)
  log("Authorization status: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
  if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
   guard await AVCaptureDevice.requestAccess(for: .audio) else { log("DENIED"); exit(2) }
  }
  let inputs = AudioDevices.inputs()
  var routes: [(String, String)] = [("Automatic", "auto")]
  if let mic = inputs.first(where: { $0.isBuiltIn }) { routes.append(("Built-in", mic.uid)) }
  if let mic = inputs.first(where: { $0.isBluetooth }) { routes.append(("Bluetooth", mic.uid)) }
  let recorder = Recorder()
  var failures = 0
  for (name, device) in routes {
   for attempt in 1...2 {
    let t = Date(); var ready: Double?; var previous = 0; var first: Double?; var lastProgress = 0.0; var maxGap = 0.0
    do { try recorder.start(selection: device) } catch { log("\(name) start error: \(error)"); continue }
    for _ in 0..<240 {
     try? await Task.sleep(for: .milliseconds(25))
     let count = recorder.count; let elapsed = Date().timeIntervalSince(t)
     if recorder.status == .recording, ready == nil { ready = elapsed }
     if count > previous {
      if first == nil { first = elapsed }
      maxGap = max(maxGap, elapsed - lastProgress); lastProgress = elapsed; previous = count
     }
    }
    let statusBeforeStop = recorder.status
    let countBeforeStop = recorder.count
    recorder.stop()
    try? await Task.sleep(for: .milliseconds(200))
    if statusBeforeStop != .recording || ready == nil || recorder.count == 0 || recorder.count != countBeforeStop || recorder.status != .idle { failures += 1 }
    log("\(name) attempt=\(attempt) first_ms=\(first.map { Int($0 * 1000) } ?? -1) ready_ms=\(ready.map { Int($0 * 1000) } ?? -1) samples=\(recorder.count) longest_gap_ms=\(Int(maxGap * 1000))")
   }
  }
  try? recorder.start(selection: "auto")
  recorder.stop()
  try? await Task.sleep(for: .milliseconds(250))
  if recorder.status != .idle || recorder.count != 0 { failures += 1 }
  log("Immediate cancellation: \(recorder.status), samples=\(recorder.count)")
  log(failures == 0 ? "PASS" : "FAIL: \(failures) checks failed")
  exit(failures == 0 ? 0 : 1)
 }
}

@main struct ProbeApp {
 @MainActor static func main() {
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 110), styleMask: [.titled, .closable], backing: .buffered, defer: false)
  window.title = "MurmurBee microphone startup test"
  let label = NSTextField(labelWithString: "Testing Automatic, built-in, and Bluetooth input. Audio is not saved.")
  label.frame = NSRect(x: 20, y: 35, width: 410, height: 45)
  label.lineBreakMode = .byWordWrapping
  window.contentView?.addSubview(label)
  window.center(); window.makeKeyAndOrderFront(nil)
  Task { await CaptureComparison.run() }
  app.run()
 }
}
