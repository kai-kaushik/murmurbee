import AppKit

/// macOS refuses to quit an app while one of its windows shows a sheet (Settings, Send feedback, a delete
/// confirmation), and says nothing. That left Sparkle's "Install and Relaunch" waiting until the sheet was closed
/// and the app quit by hand. So every way of quitting closes the sheets first, waits for them to finish closing
/// (a sheet stays attached until its close animation ends), then quits.
final class MurmurBeeApplication: NSApplication {
    /// Clears the main window's sheet state (Settings, Send feedback), so SwiftUI closes them itself.
    var closeSheets: () -> Void = {}
    private var waitingForSheets = false

    private var hasSheet: Bool { windows.contains { $0.attachedSheet != nil } }

    override func terminate(_ sender: Any?) {
        if waitingForSheets { return }
        guard hasSheet else { super.terminate(sender); return }
        waitingForSheets = true
        closeSheets()
        for window in windows { endSheets(of: window) }
        terminateWhenSheetsClose(sender, triesLeft: 40)
    }

    /// Quit requests from other apps (Sparkle's installer, the Dock, logging out) go through `terminate` too.
    func routeQuitEvents() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        terminate(nil)
    }

    /// Checks every 50 ms, for up to two seconds.
    private func terminateWhenSheetsClose(_ sender: Any?, triesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            if hasSheet && triesLeft > 0 { return terminateWhenSheetsClose(sender, triesLeft: triesLeft - 1) }
            waitingForSheets = false
            finishTerminate(sender)
        }
    }

    private func finishTerminate(_ sender: Any?) { super.terminate(sender) }

    /// Innermost first: a confirmation can sit on top of the Settings sheet.
    private func endSheets(of window: NSWindow) {
        guard let sheet = window.attachedSheet else { return }
        endSheets(of: sheet)
        window.endSheet(sheet)
    }
}
