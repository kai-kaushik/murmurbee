import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI

/// Live permission state, polled while a window that shows it is open.
@MainActor
@Observable
final class Permissions {
    var microphone = false
    var accessibility = false
    var inputMonitoring = false
    var listening = false
    var modelsReady = false
    var modelStatus = "Loading models…"
    var allGranted: Bool { microphone && accessibility && inputMonitoring }

    func refresh(listening: Bool) {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        self.listening = listening
    }
}

enum SystemPane {
    static func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
    static let accessibility = "Privacy_Accessibility"
    static let inputMonitoring = "Privacy_ListenEvent"
    static let microphone = "Privacy_Microphone"
}

// MARK: - First-run setup

struct SetupView: View {
    let permissions: Permissions
    let settings: Settings
    let relaunch: () -> Void
    let done: () -> Void
    /// Celebrate as soon as the window opens (setup finished across a restart, e.g. macOS's "Quit & Reopen").
    var celebrateOnAppear = false
    @State private var tryText = ""
    @State private var confetti = 0

    private var allSet: Bool { permissions.allGranted && permissions.listening }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                if let bee = Brand.bee {
                    Image(nsImage: bee).resizable().interpolation(.high).frame(width: 58, height: 58)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if allSet {
                        Text("You’re all set").font(Brand.sora(26)).foregroundStyle(Brand.linen)
                        Text("Hold \(settings.holdKey.rawValue) in any app and start talking.")
                            .foregroundStyle(Brand.sand)
                    } else {
                        Wordmark(size: 26)
                        Text("Hold a key, speak, let go. Everything runs on this Mac.")
                            .foregroundStyle(Brand.sand)
                    }
                }
            }

            VStack(spacing: 0) {
                StepRow(ok: permissions.microphone, title: "Microphone",
                        detail: "To hear you while you hold the key.", action: "Allow") {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        if !granted { Task { @MainActor in SystemPane.open(SystemPane.microphone) } }
                    }
                }
                Divider()
                StepRow(ok: permissions.accessibility, title: "Accessibility",
                        detail: "To paste at your cursor and read the app you're in.", action: "Open Settings") {
                    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    SystemPane.open(SystemPane.accessibility)
                }
                Divider()
                StepRow(ok: permissions.inputMonitoring && permissions.listening, title: "Input Monitoring",
                        detail: permissions.inputMonitoring && !permissions.listening
                            ? "Granted. Relaunch MurmurBee to start listening for the key."
                            : "To notice when you hold \(settings.holdKey.rawValue).",
                        action: permissions.inputMonitoring && !permissions.listening ? "Relaunch" : "Open Settings") {
                    if permissions.inputMonitoring { relaunch() } else {
                        _ = CGRequestListenEventAccess()
                        SystemPane.open(SystemPane.inputMonitoring)
                    }
                }
                Divider()
                StepRow(ok: permissions.modelsReady, title: "Speech and cleanup models",
                        detail: permissions.modelStatus, action: nil, busy: !permissions.modelsReady) {}
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.border))

            VStack(alignment: .leading, spacing: 8) {
                Text("Try it").font(.headline)
                Text("Click in the box, hold **\(settings.holdKey.rawValue)** and say: “Hi, I'm testing this, um, on Tuesday, no, Wednesday.”")
                    .font(.callout).foregroundStyle(Brand.sand)
                TextEditor(text: $tryText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Brand.raised))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.border))
                    .disabled(!(permissions.allGranted && permissions.listening && permissions.modelsReady))
            }

            HStack {
                Picker("Hold to talk", selection: Binding(get: { settings.holdKey }, set: { settings.holdKey = $0 })) {
                    ForEach(Hotkey.Key.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 230)
                Spacer()
                Button(allSet ? "Start dictating" : "Finish later") { done() }
                    .buttonStyle(HoneyButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .overlay(Confetti(trigger: confetti))
        .onChange(of: allSet) { if allSet { confetti += 1 } }
        .onAppear { if celebrateOnAppear && allSet { confetti += 1 } }
        .brandWindow()
    }
}

private struct StepRow: View {
    let ok: Bool
    let title: String
    let detail: String
    let action: String?
    var busy = false
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if ok {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.honey)
                } else if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 18))
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(Brand.sand)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action, !ok { Button(action, action: perform) }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Settings

/// Honey pill button with dark text (white on honey is hard to read).
struct HoneyButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Brand.night)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(Brand.honey.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

struct GeneralTab: View {
    @Bindable var settings: Settings
    let permissions: Permissions
    @State private var mics = AudioDevices.inputs()

    var body: some View {
        Form {
            Section {
                Picker("Hold to talk", selection: $settings.holdKey) {
                    ForEach(Hotkey.Key.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Hands-free: double-tap to start, tap to finish", isOn: $settings.handsFree)
                Toggle("Play a sound when recording starts and stops", isOn: $settings.playSounds)
                Text("Esc cancels a dictation at any time.").font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Picker("Bar position", selection: $settings.barEdge) {
                    Text("Bottom").tag(PillModel.Edge.bottom)
                    Text("Left").tag(PillModel.Edge.left)
                    Text("Right").tag(PillModel.Edge.right)
                }
                Toggle("Show the bar when not dictating", isOn: $settings.showBarWhenIdle)
                Text("You can also drag the bar to any edge. Click it to start or finish a dictation.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Picker("Microphone", selection: $settings.microphone) {
                    Text("Automatic (avoid Bluetooth headsets)").tag("auto")
                    Text("System default").tag("default")
                    if !mics.isEmpty { Divider() }
                    ForEach(mics) { Text($0.name).tag($0.uid) }
                }
                Toggle("Clean up with AI", isOn: $settings.cleanupOn)
                TextField("Name you sign with", text: $settings.signName, prompt: Text(NSFullUserName()))
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin },
                                                        set: { settings.launchAtLogin = $0 }))
            }
            Section("Status") {
                LabeledContent("Models", value: permissions.modelStatus)
                LabeledContent("Microphone", value: permissions.microphone ? "Allowed" : "Not allowed")
                LabeledContent("Accessibility", value: permissions.accessibility ? "Allowed" : "Not allowed")
                LabeledContent("Input Monitoring", value: permissions.inputMonitoring
                    ? (permissions.listening ? "Allowed, listening" : "Allowed, relaunch needed") : "Not allowed")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { mics = AudioDevices.inputs() }
    }
}

struct PrivacyTab: View {
    @Bindable var settings: Settings
    let deleteHistory: () -> Void
    @State private var confirming = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Network") {
                    Text("None. Speech and cleanup run on this Mac; nothing is sent anywhere.")
                        .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                }
                LabeledContent("Audio") {
                    Text("Never kept. Only the text of each dictation is saved.").foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Learn from my edits", isOn: $settings.learnFromEdits)
                Text("After pasting, MurmurBee re-reads the field once or twice to see what you corrected, so it can get those words right next time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Show History Folder") { NSWorkspace.shared.open(Store.directory) }
                    Spacer()
                    Button("Delete All History…", role: .destructive) { confirming = true }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog("Delete all dictation history?", isPresented: $confirming) {
            Button("Delete History", role: .destructive, action: deleteHistory)
        } message: {
            Text("This removes every saved dictation and captured edit from this Mac. Your dictionary is kept.")
        }
    }
}

// MARK: - Window plumbing

@MainActor
final class WindowManager {
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(_ id: String, title: String, resizable: Bool = false, @ViewBuilder content: () -> V) {
        if let w = windows[id] {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: content()))
        w.title = title
        w.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.titled, .closable]
        if resizable {
            w.setContentSize(NSSize(width: 1080, height: 720))
            w.setFrameAutosaveName("MurmurBee.\(id)")
        }
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Brand.nsNight
        w.isReleasedWhenClosed = false
        w.center()
        windows[id] = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func close(_ id: String) { windows[id]?.close() }
    func isOpen(_ id: String) -> Bool { windows[id]?.isVisible ?? false }
}
