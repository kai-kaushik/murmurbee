import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings = Settings.shared
    private let permissions = Permissions()
    private let windows = WindowManager()
    private let hotkey = Hotkey()
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private let cleaner = Cleaner()
    private let inserter = Inserter()
    private let store = Store()
    private let pill = PillWindow()

    private var ready = false
    private var status = "Loading models…"
    private var session: Session?
    private var context = ContextSnapshot()
    private var recent: [(text: String, ms: Double)] = []

    /// Hold-to-talk plus hands-free (double-tap to start, tap to finish).
    private enum KeyState { case idle, holding(Date), tapPending, latched, ignoreUp }
    private var keyState = KeyState.idle

    /// The newest cleanup model installed (v3, then v2, then v1).
    static let modelDir: URL = {
        let models = Store.directory.appendingPathComponent("models")
        for name in ["qwen35-0.8b-kai-v3", "qwen35-0.8b-kai-v2", "qwen35-0.8b-kai-v1"] {
            let dir = models.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dir.path) { return dir }
        }
        return models.appendingPathComponent("qwen35-0.8b-kai-v1")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.autosaveName = "MurmurBeeStatusItem"  // remembers its spot if you ⌘-drag it
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MurmurBee")
        rebuildMenu()

        pill.configure(edge: settings.barEdge, showWhenIdle: settings.showBarWhenIdle,
                       keyName: settings.holdKey.short)
        pill.onClick = { [weak self] in self?.pillClicked() }
        pill.onEdgeChanged = { [weak self] edge in self?.settings.barEdge = edge }
        settings.onBarChange = { [weak self] in
            guard let self else { return }
            self.pill.configure(edge: self.settings.barEdge, showWhenIdle: self.settings.showBarWhenIdle,
                                keyName: self.settings.holdKey.short)
        }

        hotkey.onDown = { [weak self] in self?.keyDown() }
        hotkey.onUp = { [weak self] in self?.keyUp() }
        hotkey.onCancel = { [weak self] in self?.cancel() }
        hotkey.onEscape = { [weak self] in if self?.session != nil { self?.cancel() } }
        startHotkey()

        // Keep permission state fresh for the menu and windows.
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        refreshPermissions()
        if !settings.onboarded || !permissions.allGranted { showSetup() }

        Task {
            do {
                let t = Date()
                permissions.modelStatus = "Loading speech model…"
                try await transcriber.load()
                permissions.modelStatus = "Loading cleanup model…"
                try await cleaner.load(from: Self.modelDir)
                ready = true
                status = String(format: "Ready · models loaded in %.0fs", Date().timeIntervalSince(t))
                permissions.modelStatus = "Ready (\(await cleaner.origin))"
                permissions.modelsReady = true
                if permissions.allGranted && hotkey.isListening {
                    pill.flash("MurmurBee ready · hold \(settings.holdKey.rawValue)", seconds: 3)
                }
            } catch {
                status = "Model load failed: \(error.localizedDescription)"
                permissions.modelStatus = status
            }
            rebuildMenu()
        }
    }

    /// Opening the app again (Finder, Spotlight, Dock) pops the menu up at the cursor,
    /// so it's reachable even when the menu-bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        rebuildMenu()
        statusItem.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    // MARK: Keys

    private func keyDown() {
        switch keyState {
        case .idle:
            if begin() { keyState = .holding(Date()) }
        case .tapPending:  // second tap of a double-tap: keep recording without holding
            keyState = .latched
            pill.model.hint = "Tap \(settings.holdKey.rawValue) to finish"
        case .latched:
            keyState = .ignoreUp
            finish()
        case .holding, .ignoreUp:
            break
        }
    }

    private func keyUp() {
        switch keyState {
        case .holding(let since):
            if settings.handsFree && Date().timeIntervalSince(since) < 0.3 {
                keyState = .tapPending  // maybe the first tap of a double-tap
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    if case .tapPending = keyState { cancel() }  // just a stray tap
                }
            } else {
                keyState = .idle
                finish()
            }
        case .ignoreUp:
            keyState = .idle
        default:
            break
        }
    }

    /// Clicking the bar starts a hands-free dictation; clicking again finishes it.
    private func pillClicked() {
        switch keyState {
        case .idle where session == nil:
            if begin() {
                keyState = .latched
                pill.model.hint = "Click to finish"
            }
        case .latched:
            keyState = .idle
            finish()
        default:
            break
        }
    }

    // MARK: Dictation

    private func begin() -> Bool {
        guard ready, session == nil else {
            if !ready { pill.flash("Still loading models…") }
            return false
        }
        context = ContextSnapshot.capture()
        if context.isSecureField { pill.flash("Password field, not recording"); return false }
        let s = Session(recorder: recorder, transcriber: transcriber, cleaner: cleaner,
                        context: context, cleanupOn: settings.cleanupOn)
        s.onLevel = { [weak self] in self?.pill.model.level = $0 }
        let pid = context.pid
        s.screenNames = Task.detached { Vocabulary.screenNames(pid: pid) }
        do {
            try s.start(device: AudioDevices.resolve(settings.microphone))
            session = s
            pill.model.hint = nil
            pill.show(.listening)
            Sounds.play(.start)
            return true
        } catch {
            pill.flash("Microphone unavailable")
            return false
        }
    }

    private func finish() {
        guard let s = session else { return }
        session = nil
        let released = Date()
        pill.show(.finishing)
        Sounds.play(.stop)
        Task {
            let r = await s.finish()
            guard !r.cleaned.isEmpty else { pill.flash("No speech heard"); return }
            pill.show(.idle)
            let ctx = context
            // Latency is release → ⌘V sent; verification happens after, off the critical path.
            let totalMs = Date().timeIntervalSince(released) * 1000
            inserter.insert(r.cleaned) { [weak self] outcome in
                self?.record(r, context: ctx, totalMs: totalMs, outcome: outcome)
            }
            recent.insert((r.cleaned, totalMs), at: 0)
            recent = Array(recent.prefix(20))
            rebuildMenu()
        }
    }

    private func cancel() {
        if session != nil { Sounds.play(.cancel) }
        session?.cancel()
        session = nil
        keyState = .idle
        pill.show(.idle)
    }

    private func record(_ r: Session.Result, context: ContextSnapshot, totalMs: Double, outcome: Inserter.Outcome) {
        if outcome.method == .clipboardOnly { pill.flash("Couldn't paste here. Press ⌘V", seconds: 2.5) }
        let learn = settings.learnFromEdits
        Task {
            var rec = DictationRecord()
            rec.context = context
            rec.durationS = r.durationS
            rec.chunks = r.chunks
            rec.asrText = r.raw
            rec.cleanedText = r.cleaned
            rec.cleanupPaths = r.paths
            rec.insertMethod = outcome.method.rawValue
            rec.insertConfirmed = outcome.confirmed
            rec.latencyTotalMs = totalMs
            rec.latencyAsrFinalMs = r.asrFinalMs
            rec.latencyCleanupFinalMs = r.cleanFinalMs
            rec.cleanupOrigin = await cleaner.origin
            rec.vocab = r.vocab.joined(separator: "; ")
            if learn { rec.fieldAfter = outcome.fieldAfter }
            let id = await store.save(rec)
            if learn, let field = outcome.field, let after = outcome.fieldAfter {
                watchEdits(field, row: id, inserted: r.cleaned, after: after)
            }
        }
    }

    /// Learning from edits: watch the field for a minute after pasting (every 2 s), keeping the last version
    /// that still contains the text around our paste, i.e. before the user sends or clears it. When it settles,
    /// save the edited text, add corrected names to the dictionary, and say so on the bar, like Wispr.
    private func watchEdits(_ field: AXUIElement, row: Int64, inserted: String, after: String) {
        Task { @MainActor in
            var latest: String?
            var lastChange = Date()
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                guard let now = Inserter.value(field) else { break }
                guard EditLearner.editedSpan(inserted: inserted, after: after, later: now) != nil else { break }
                if now != (latest ?? after) { latest = now; lastChange = Date() }
                if latest != nil && Date().timeIntervalSince(lastChange) > 6 { break }  // edits have settled
            }
            guard let later = latest,
                  let span = EditLearner.editedSpan(inserted: inserted, after: after, later: later),
                  span != inserted else { return }
            await store.setText(row, "field_later", later)
            await store.setText(row, "edited_text", span)
            let known = Set(Vocabulary.dictionary())
            let terms = EditLearner.learnedTerms(inserted: inserted, edited: span, known: known)
            guard !terms.isEmpty else { return }
            EditLearner.addToDictionary(terms)
            let list = terms.map { "“\($0)”" }.joined(separator: ", ")
            pill.flash("Added \(list) to dictionary", seconds: 2.5)
        }
    }

    // MARK: Permissions and windows

    private func refreshPermissions() {
        permissions.refresh(listening: hotkey.isListening)
    }

    private func startHotkey() {
        if !hotkey.start() {
            // Input Monitoring not granted yet: retry quietly until it is.
            Task {
                try? await Task.sleep(for: .seconds(2))
                startHotkey()
            }
        }
    }

    private func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    @objc private func showSetup() {
        windows.show("setup", title: "MurmurBee") {
            SetupView(permissions: permissions, settings: settings, relaunch: { [weak self] in self?.relaunch() },
                      done: { [weak self] in
                          self?.settings.onboarded = true
                          self?.windows.close("setup")
                      })
        }
    }

    @objc private func showSettings() {
        windows.show("settings", title: "MurmurBee Settings") {
            SettingsView(settings: settings, permissions: permissions,
                         deleteHistory: { [weak self] in
                             guard let self else { return }
                             Task {
                                 await self.store.deleteAll()
                                 self.recent.removeAll()
                                 self.rebuildMenu()
                             }
                         })
        }
    }

    // MARK: Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        let missing = permissionLines().filter { !$0.1 }
        if missing.isEmpty {
            menu.addItem(withTitle: "Hold \(settings.holdKey.rawValue) to talk", action: nil, keyEquivalent: "")
        } else {
            for (name, _) in missing { menu.addItem(withTitle: "✗  \(name) needed", action: nil, keyEquivalent: "") }
            add(menu, "Finish Setup…", #selector(showSetup))
        }
        if let last = recent.first {
            menu.addItem(withTitle: String(format: "Last: %.0f ms from release to paste", last.ms),
                         action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())

        let paste = add(menu, "Paste Last Dictation", #selector(pasteLast))
        paste.isEnabled = !recent.isEmpty
        let cleanup = add(menu, "Clean Up with AI", #selector(toggleCleanup))
        cleanup.state = settings.cleanupOn ? .on : .off

        if !recent.isEmpty {
            let sub = NSMenu()
            for (i, r) in recent.enumerated() {
                let title = r.text.count > 70 ? String(r.text.prefix(70)) + "…" : r.text
                let item = NSMenuItem(title: title.replacingOccurrences(of: "\n", with: " "),
                                      action: #selector(copyRecent(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                sub.addItem(item)
            }
            let recentItem = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            recentItem.submenu = sub
            menu.addItem(recentItem)
        }

        menu.addItem(.separator())
        let s = add(menu, "Settings…", #selector(showSettings))
        s.keyEquivalent = ","
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MurmurBee", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func permissionLines() -> [(String, Bool)] {
        [("Microphone", permissions.microphone), ("Accessibility", permissions.accessibility),
         ("Input Monitoring", permissions.inputMonitoring && permissions.listening)]
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshPermissions()
    }

    @objc private func toggleCleanup() {
        settings.cleanupOn.toggle()
        rebuildMenu()
    }

    @objc private func pasteLast() {
        guard let text = recent.first?.text else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))  // let the menu close and focus return
            inserter.insert(text) { [weak self] outcome in
                if outcome.method == .clipboardOnly { self?.pill.flash("Couldn't paste here. Press ⌘V") }
            }
        }
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recent[sender.tag].text, forType: .string)
    }
}
