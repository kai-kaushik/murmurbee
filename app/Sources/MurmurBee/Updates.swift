import Foundation
import Observation
import Sparkle

/// The app's one Sparkle updater (feed and public key are in Info.plist). Used by the menu-bar menu, the MurmurBee
/// menu and the Updates page, which shows what the last check found.
@MainActor
@Observable
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()
    static var controller: SPUStandardUpdaterController { shared.controller }

    /// The newer version the last check found, if any (shown on the Updates page and as a dot in the sidebar).
    var available: String?
    var lastChecked: Date?
    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    override private init() {
        super.init()
        lastChecked = controller.updater.lastUpdateCheckDate
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    static func checkNow() { controller.checkForUpdates(nil) }
    static var automatic: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    /// Downloads in the background and installs when MurmurBee next quits.
    static var installAutomatically: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        available = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        available = nil
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastChecked = updater.lastUpdateCheckDate
    }
}

/// What changed in each version, shown on the Updates page. Add the new version's lines with each release.
@MainActor
enum ReleaseNotes {
    static let byVersion: [String: [String]] = [
        "0.1.9": [
            "Updates has its own page in the sidebar, with what's new in each version.",
            "A short tour after setup: speak a list, go hands-free, move the bar. Find it again in the MurmurBee menu.",
            "Lists spoken as \"Firstly…. Secondly…. And thirdly…\" become numbered lists too.",
            "Install and Relaunch now works even with Settings open.",
        ],
        "0.1.8": [
            "The hands-free hint floats above the flow bar for a moment, then fades.",
        ],
        "0.1.7": [
            "Spoken lists (\"first…, second…, third…\") become numbered lists.",
            "Double fn and double right Option no longer also start Apple Dictation or other apps.",
        ],
    ]
    static var current: [String] { byVersion[Updates.version] ?? [] }
}
