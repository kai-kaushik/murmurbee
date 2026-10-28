import Sparkle

/// The app's one Sparkle updater (feed and public key are in Info.plist). Used by the menu-bar menu, the MurmurBee
/// menu and Settings.
@MainActor
enum Updates {
    static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                         userDriverDelegate: nil)
    static func checkNow() { controller.checkForUpdates(nil) }
    static var automatic: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
