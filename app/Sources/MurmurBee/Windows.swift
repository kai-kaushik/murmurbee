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
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(Brand.honeyFill.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

// MARK: - Settings building blocks

/// A titled group of settings rows on one rounded card, with room to breathe.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.9)
                .foregroundStyle(Brand.sand)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
        }
    }
}

/// One setting: a title with an optional quiet explanation underneath, and its control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    var divider = true
    @ViewBuilder var control: Control
    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(Brand.border.opacity(0.55)).frame(height: 1).padding(.leading, 20) }
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Brand.linen)
                    if let detail {
                        Text(detail).font(.system(size: 12.5)).foregroundStyle(Brand.sand)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 20).padding(.vertical, 15)
        }
    }
}

private extension View {
    func settingsToggle() -> some View { toggleStyle(.switch).tint(Brand.honeyFill).labelsHidden() }
    func settingsPicker(_ width: CGFloat = 190) -> some View { labelsHidden().pickerStyle(.menu).frame(width: width) }
}

struct GeneralTab: View {
    @Bindable var settings: Settings
    let permissions: Permissions
    @State private var mics = AudioDevices.inputs()
    @State private var appearance = Theme.mode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsSection(title: "Dictation") {
                    SettingsRow(title: "Hold to talk", detail: "Hold the key, speak, let go. Esc cancels at any time.", divider: false) {
                        Picker("Hold to talk", selection: $settings.holdKey) {
                            ForEach(Hotkey.Key.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.settingsPicker()
                    }
                    SettingsRow(title: "Hands-free", detail: "Double-tap the key to start, tap once to finish.") {
                        Toggle("Hands-free", isOn: $settings.handsFree).settingsToggle()
                    }
                    SettingsRow(title: "Clean up with AI", detail: "Tidies wording, punctuation and lists on this Mac.") {
                        Toggle("Clean up with AI", isOn: $settings.cleanupOn).settingsToggle()
                    }
                    SettingsRow(title: "Name you sign with", detail: "Used for email sign-offs like “Best, \(firstName)”.") {
                        TextField("Name", text: $settings.signName, prompt: Text(NSFullUserName()))
                            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Brand.raised))
                            .frame(width: 190)
                    }
                }

                SettingsSection(title: "Flow bar and sound") {
                    SettingsRow(title: "Bar position", detail: "You can also drag the bar to any edge.", divider: false) {
                        Picker("Bar position", selection: $settings.barEdge) {
                            Text("Bottom").tag(PillModel.Edge.bottom)
                            Text("Left").tag(PillModel.Edge.left)
                            Text("Right").tag(PillModel.Edge.right)
                        }.settingsPicker(120)
                    }
                    SettingsRow(title: "Show the bar when idle", detail: "Click it to start or finish a dictation.") {
                        Toggle("Show the bar when idle", isOn: $settings.showBarWhenIdle).settingsToggle()
                    }
                    SettingsRow(title: "Sounds", detail: "A soft chime when recording starts and stops.") {
                        Toggle("Sounds", isOn: $settings.playSounds).settingsToggle()
                    }
                }

                SettingsSection(title: "System") {
                    SettingsRow(title: "Microphone", detail: "Automatic avoids Bluetooth headset mics, which sound worse.", divider: false) {
                        Picker("Microphone", selection: $settings.microphone) {
                            Text("Automatic").tag("auto")
                            Text("System default").tag("default")
                            if !mics.isEmpty { Divider() }
                            ForEach(mics) { Text($0.name).tag($0.uid) }
                        }.settingsPicker()
                    }
                    SettingsRow(title: "Appearance", detail: "Match your Mac, or keep MurmurBee light or dark.") {
                        Picker("Appearance", selection: Binding(get: { appearance }, set: { appearance = $0; Theme.set($0) })) {
                            Text("System").tag(Theme.Mode.system)
                            Text("Light").tag(Theme.Mode.light)
                            Text("Dark").tag(Theme.Mode.dark)
                        }.settingsPicker(120)
                    }
                    SettingsRow(title: "Launch at login") {
                        Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin },
                                                                set: { settings.launchAtLogin = $0 })).settingsToggle()
                    }
                }

                SettingsSection(title: "Status") {
                    status("Models", permissions.modelStatus, permissions.modelsReady, first: true)
                    status("Microphone", permissions.microphone ? "Allowed" : "Not allowed", permissions.microphone)
                    status("Accessibility", permissions.accessibility ? "Allowed" : "Not allowed", permissions.accessibility)
                    status("Input Monitoring",
                           permissions.inputMonitoring ? (permissions.listening ? "Allowed, listening" : "Allowed, relaunch needed") : "Not allowed",
                           permissions.inputMonitoring && permissions.listening)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
        .scrollIndicators(.never)
        .onAppear { mics = AudioDevices.inputs() }
    }

    private var firstName: String {
        let n = settings.signName.isEmpty ? NSFullUserName() : settings.signName
        return n.split(separator: " ").first.map(String.init) ?? "Sam"
    }

    private func status(_ title: String, _ value: String, _ ok: Bool, first: Bool = false) -> some View {
        SettingsRow(title: title, divider: !first) {
            HStack(spacing: 8) {
                Circle().fill(ok ? Brand.honey : Color(red: 0.95, green: 0.63, blue: 0.48)).frame(width: 7, height: 7)
                Text(value).font(.system(size: 13)).foregroundStyle(Brand.sand).lineLimit(1)
            }
        }
    }
}

struct PrivacyTab: View {
    @Bindable var settings: Settings
    let deleteHistory: () -> Void
    @State private var confirming = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsSection(title: "On this Mac") {
                    SettingsRow(title: "Network", detail: "None. Speech and cleanup run on this Mac; nothing is sent anywhere.", divider: false) {
                        Image(systemName: "checkmark.shield").foregroundStyle(Brand.honey)
                    }
                    SettingsRow(title: "Audio", detail: "Never kept. Only the text of each dictation is saved.") {
                        Image(systemName: "waveform.slash").foregroundStyle(Brand.honey)
                    }
                }
                SettingsSection(title: "Learning") {
                    SettingsRow(title: "Learn from my edits",
                                detail: "After pasting, MurmurBee re-reads the field once or twice to see what you corrected, so it gets those words right next time.",
                                divider: false) {
                        Toggle("Learn from my edits", isOn: $settings.learnFromEdits).settingsToggle()
                    }
                }
                SettingsSection(title: "Your data") {
                    SettingsRow(title: "History folder", detail: "Your dictation history and dictionary, as plain files.", divider: false) {
                        Button("Show in Finder") { NSWorkspace.shared.open(Store.directory) }
                    }
                    SettingsRow(title: "Delete all history", detail: "Removes every saved dictation. Your dictionary is kept.") {
                        Button("Delete…", role: .destructive) { confirming = true }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
        .scrollIndicators(.never)
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
