import Foundation
import Observation
import ServiceManagement

/// Every user setting, backed by UserDefaults. One screen's worth, per the PRD.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var holdKey: Hotkey.Key {
        didSet { d.set(holdKey.rawValue, forKey: "holdKey"); Hotkey.consumedKeyCode.store(holdKey.keyCode, ordering: .relaxed); onBarChange() }
    }
    /// Double-tap the hold key to dictate without holding; tap again to finish.
    var handsFree: Bool {
        didSet { d.set(handsFree, forKey: "handsFree") }
    }
    var cleanupOn: Bool {
        didSet { d.set(cleanupOn, forKey: "cleanupOn") }
    }
    /// A soft tick when recording starts and another when you let go, like Wispr.
    var playSounds: Bool {
        didSet { d.set(playSounds, forKey: "playSounds") }
    }
    /// The name you sign emails with ("Regards, Sam"). Empty = your macOS account name.
    var signName: String {
        didSet { d.set(signName, forKey: "signName") }
    }
    /// "auto" (system default, but never a Bluetooth headset mic), "default", or a CoreAudio device UID.
    var microphone: String {
        didSet { d.set(microphone, forKey: "microphone") }
    }
    /// Which screen edge the flow bar docks to (drag it to change), and whether it shows when idle.
    var barEdge: PillModel.Edge {
        didSet { d.set(barEdge.rawValue, forKey: "barEdge"); onBarChange() }
    }
    var showBarWhenIdle: Bool {
        didSet { d.set(showBarWhenIdle, forKey: "showBarWhenIdle"); onBarChange() }
    }
    @ObservationIgnored var onBarChange: () -> Void = {}

    var onboarded: Bool {
        didSet { d.set(onboarded, forKey: "onboarded") }
    }
    /// Opt-in: send rounded weekly totals (see WeeklyTotals). Off until you say yes.
    var shareTotals: Bool {
        didSet { d.set(shareTotals, forKey: "shareTotals"); WeeklyTotals.settingChanged(shareTotals) }
    }
    /// Whether Home has asked (yes or not now), so it only asks once.
    var shareTotalsAsked: Bool {
        didSet { d.set(shareTotalsAsked, forKey: "shareTotalsAsked") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            launchAtLoginTick += 1
        }
    }
    private var launchAtLoginTick = 0  // lets SwiftUI re-read the system status after a change

    /// On by default: the first launch of the installed app adds it to login items, once. Turning it off sticks.
    func defaultLaunchAtLogin() {
        guard !d.bool(forKey: "launchAtLoginDefaulted"), Bundle.main.bundleURL.pathExtension == "app" else { return }
        d.set(true, forKey: "launchAtLoginDefaulted")
        if SMAppService.mainApp.status != .enabled { launchAtLogin = true }
    }

    /// Settings saved under the app's old identifier (com.kaigen.murmurbee) carry over once.
    private static func migrateDefaults(into d: UserDefaults) {
        guard !d.bool(forKey: "migratedFromKaigen"),
              let old = UserDefaults(suiteName: "com.kaigen.murmurbee")?.persistentDomain(forName: "com.kaigen.murmurbee")
        else { return }
        for (key, value) in old where d.object(forKey: key) == nil && !key.hasPrefix("NS") { d.set(value, forKey: key) }
        d.set(true, forKey: "migratedFromKaigen")
    }

    private init() {
        Self.migrateDefaults(into: d)
        holdKey = d.string(forKey: "holdKey").flatMap(Hotkey.Key.init(rawValue:)) ?? .rightOption
        barEdge = d.string(forKey: "barEdge").flatMap(PillModel.Edge.init(rawValue:)) ?? .bottom
        showBarWhenIdle = d.object(forKey: "showBarWhenIdle") as? Bool ?? true
        handsFree = d.object(forKey: "handsFree") as? Bool ?? true
        cleanupOn = d.object(forKey: "cleanupOn") as? Bool ?? true
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        signName = d.string(forKey: "signName") ?? ""
        microphone = d.string(forKey: "microphone") ?? "auto"
        onboarded = d.bool(forKey: "onboarded")
        shareTotals = d.bool(forKey: "shareTotals")
        shareTotalsAsked = d.bool(forKey: "shareTotalsAsked")
    }
}
