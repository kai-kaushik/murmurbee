import AppKit
import SwiftUI

/// Debug aid: draw each window offscreen and save it, so UI changes can be reviewed without clicking around.
@MainActor
enum Snapshots {
    static func render(to dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Permissions()
        p.refresh(listening: false)
        p.modelStatus = "Loading cleanup model…"
        save(SetupView(permissions: p, settings: .shared, relaunch: {}, done: {}), "setup", dir)
        p.modelsReady = true
        p.modelStatus = "Ready (murmurbee-cleanup-v1)"
        save(HubView(model: HubModel(), store: Store(), settings: .shared, permissions: p, deleteHistory: {})
                .frame(width: 920, height: 640), "hub", dir)
        let s = HubModel(); s.pane = .dictionary
        save(HubView(model: s, store: Store(), settings: .shared, permissions: p, deleteHistory: {})
                .frame(width: 920, height: 640), "hub-dictionary", dir)
        save(HubView(model: HubModel(), store: Store(), settings: .shared, permissions: p, deleteHistory: {})
                .frame(width: 1080, height: 720), "hub-light", dir, light: true)
        let u = HubModel(); u.pane = .updates
        Updates.shared.lastChecked = Date().addingTimeInterval(-3 * 3600)
        save(HubView(model: u, store: Store(), settings: .shared, permissions: p, deleteHistory: {})
                .frame(width: 920, height: 640), "hub-updates", dir)
        save(HubView(model: u, store: Store(), settings: .shared, permissions: p, deleteHistory: {})
                .frame(width: 920, height: 640), "hub-updates-light", dir, light: true)
        Updates.shared.available = "0.1.9"
        save(HubView(model: u, store: Store(), settings: .shared, permissions: p, deleteHistory: {})
                .frame(width: 920, height: 640), "hub-updates-available", dir)
        Updates.shared.available = nil
        let tour = TourModel()
        func tourShot(_ name: String, edge: PillModel.Edge = .bottom, light: Bool = false) {
            save(TourView(settings: .shared, tour: tour, edge: .constant(edge), animate: false, done: {}), name, dir, light: light)
        }
        tour.keyHeld = true
        tourShot("tour-1-holding")
        tour.keyHeld = false
        tour.listText = PostEdit.formatSpokenList(TourView.listSentence)
        tourShot("tour-1")
        tourShot("tour-1-light", light: true)
        tour.step = 1
        tour.handsFree = .talking
        tourShot("tour-2-talking")
        tour.handsFree = .done
        tour.handsFreeText = "I'm trying hands-free mode. This is nice, I can just talk without holding anything down."
        tourShot("tour-2-done")
        tour.step = 2
        tourShot("tour-3", edge: .left)
        tourShot("tour-3-light", edge: .left, light: true)
        save(GeneralTab(settings: .shared, permissions: p).frame(width: 600, height: 900).background(Brand.night),
             "settings-light", dir, light: true)
        save(GeneralTab(settings: .shared, permissions: p).frame(width: 600, height: 900).background(Brand.night), "settings-general", dir)
        save(PrivacyTab(settings: .shared, deleteHistory: {}).frame(width: 600, height: 600).background(Brand.night), "settings-privacy", dir)
        // Flow bar states, on a light desktop-ish backdrop.
        let states: [(String, PillModel.State, Bool, PillModel.Edge, String?)] = [
            ("bar-idle", .idle, false, .bottom, nil), ("bar-hover", .idle, true, .bottom, nil),
            ("bar-listening", .listening, false, .bottom, nil),
            ("bar-handsfree", .listening, false, .bottom, "Tap Right Option to finish"),
            ("bar-finishing", .finishing, false, .bottom, nil), ("bar-left", .listening, false, .left, nil),
            ("bar-left-idle", .idle, false, .left, nil), ("bar-right-hover", .idle, true, .right, nil),
            ("bar-right-handsfree", .listening, false, .right, "Click to finish")]
        for (name, state, hover, edge, hint) in states {
            let m = PillModel()
            m.state = state; m.hovering = hover; m.keyName = "right ⌥"; m.edge = edge; m.level = 0.03; m.hint = hint
            let size = edge == .bottom ? CGSize(width: 360, height: 110) : CGSize(width: 330, height: 180)
            save(PillView(model: m).frame(width: size.width, height: size.height)
                    .background(LinearGradient(colors: [Color(white: 0.93), Color(white: 0.82)],
                                               startPoint: .top, endPoint: .bottom)), name, dir)
        }
        let d = DragModel()
        d.nearest = .left
        d.ghost = CGPoint(x: 260, y: 300)
        save(DragOverlayView(model: d).frame(width: 900, height: 560)
                .background(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.85)],
                                           startPoint: .top, endPoint: .bottom)), "drag-overlay", dir)
    }

    private static func save<V: View>(_ view: V, _ name: String, _ dir: URL, light: Bool = false) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
