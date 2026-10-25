import AppKit
import ApplicationServices
import SwiftUI

/// The flow bar: a small dark pill docked to the bottom, left or right edge of the screen.
/// Horizontal at the bottom, vertical on the sides. Idle it's a quiet sliver (optionally hidden);
/// while dictating it springs open into a waveform. Drag it and the screen dims and shows three drop
/// targets; release to dock at the nearest one. Click it to start or finish a hands-free dictation.
/// Behaviour and measurements follow Wispr Flow's flow bar; the implementation is our own.
@MainActor
@Observable
final class PillModel {
    enum State: Equatable { case idle, listening, finishing, message(String) }
    enum Edge: String, CaseIterable { case bottom, left, right }
    var state: State = .idle
    var level: Float = 0
    var hint: String?
    var hovering = false
    var edge: Edge = .bottom
    var showWhenIdle = true
    var keyName = "right ⌥"
    var dragging = false
    /// The bar's frame inside the panel (SwiftUI coordinates, y down), for hit-testing.
    var barFrame: CGRect = .zero

    var vertical: Bool { edge != .bottom }
    /// Text shown in a bubble beside the bar (sides) or inside it (bottom).
    var text: String? {
        switch state {
        case .message(let t): t
        case .listening: hint
        case .idle: nil
        case .finishing: nil
        }
    }
}

private struct BarFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct PillView: View {
    let model: PillModel

    var body: some View {
        Group {
            switch model.edge {
            case .bottom:
                VStack(spacing: 8) { Spacer(minLength: 0); tooltip; bottomBar }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .left:
                HStack(spacing: 8) { sideBar; tooltip; bubble; Spacer(minLength: 0) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .right:
                HStack(spacing: 8) { Spacer(minLength: 0); bubble; tooltip; sideBar }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(model.vertical ? .horizontal : .bottom, 12)
        .coordinateSpace(name: "panel")
        .onPreferenceChange(BarFrameKey.self) { model.barFrame = $0 }
        .opacity(model.dragging || (model.state == .idle && !model.showWhenIdle && !model.hovering) ? 0 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: model.state)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: model.hovering)
        .animation(.easeOut(duration: 0.15), value: model.dragging)
    }

    private var active: Bool { model.state != .idle }

    private var hoverIdle: Bool { model.state == .idle && model.hovering }

    /// Bottom edge: one horizontal capsule; messages and hints go inside it.
    private var bottomBar: some View {
        Group {
            if model.state == .idle {
                idleShape(width: hoverIdle ? 52 : 38, height: hoverIdle ? 30 : 9)
            } else {
                HStack(spacing: 8) {
                    indicator
                    if let t = model.text { Text(t).foregroundStyle(.white.opacity(0.88)).lineLimit(1) }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
            }
        }
        .background(capsule)
        .fixedSize()
        .reportFrame()
    }

    /// Side edges: a vertical capsule; text pops out beside it in its own bubble.
    private var sideBar: some View {
        Group {
            if model.state == .idle || model.text != nil && model.state != .listening {
                idleShape(width: hoverIdle ? 30 : 9, height: hoverIdle ? 52 : 38)
            } else {
                indicator.padding(.vertical, 12).frame(minWidth: 30)
            }
        }
        .background(capsule)
        .fixedSize()
        .reportFrame()
    }

    /// The resting sliver; on hover it becomes a mic button (click to dictate).
    private func idleShape(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.clear
            if hoverIdle {
                Image(systemName: "mic.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
    }

    /// "Dictate right ⌥" on hover, like Wispr's "Dictate fn".
    @ViewBuilder private var tooltip: some View {
        if hoverIdle {
            (Text("Dictate ") + Text(model.keyName).bold())
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Brand.barNight.opacity(0.88))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)))
                .fixedSize()
                .transition(.opacity.combined(with: .offset(y: model.vertical ? 0 : 4)))
        }
    }

    @ViewBuilder private var bubble: some View {
        if model.vertical, let t = model.text {
            Text(t)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Brand.barNight.opacity(0.78)))
                .fixedSize()
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    private var capsule: some View {
        Capsule().fill(Brand.barNight.opacity(active ? 0.82 : (model.hovering ? 0.85 : 0.42)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(active ? 0.12 : 0.28), lineWidth: 0.5))
            .shadow(color: .black.opacity(active ? 0.25 : 0.12), radius: active ? 9 : 4, y: active ? 4 : 1)
    }

    @ViewBuilder private var indicator: some View {
        switch model.state {
        case .listening:
            if model.vertical {
                VStack(spacing: 8) { dot; Bars(level: model.level, vertical: true) }
            } else {
                HStack(spacing: 8) { dot; Bars(level: model.level, vertical: false) }
            }
        case .finishing:
            Shimmer(vertical: model.vertical)
        case .idle, .message:
            EmptyView()
        }
    }

    private var dot: some View {
        Circle().fill(Color(red: 0.95, green: 0.3, blue: 0.32)).frame(width: 6, height: 6)
    }
}

private extension View {
    func reportFrame() -> some View {
        background(GeometryReader { p in Color.clear.preference(key: BarFrameKey.self, value: p.frame(in: .named("panel"))) })
    }
}

/// Live waveform: bars follow the mic level with a little per-bar variation. Vertical bars stack downward.
private struct Bars: View {
    let level: Float
    let vertical: Bool
    private let weights: [Float] = [0.45, 0.7, 0.95, 0.75, 1.0, 0.65, 0.85, 0.55, 0.4]

    var body: some View {
        let lengths = weights.map { CGFloat(3 + min(1, level * 20) * 15 * $0) }
        Group {
            if vertical {
                VStack(spacing: 2) {
                    ForEach(lengths.indices, id: \.self) { i in
                        Capsule().fill(Brand.barHoney).frame(width: lengths[i], height: 2.5)
                    }
                }
                .frame(width: 18)
            } else {
                HStack(spacing: 2) {
                    ForEach(lengths.indices, id: \.self) { i in
                        Capsule().fill(Brand.barHoney).frame(width: 2.5, height: lengths[i])
                    }
                }
                .frame(height: 18)
            }
        }
        .animation(.easeOut(duration: 0.09), value: level)
    }
}

/// "Finishing": a soft highlight sweeping across three dots while the last chunk is cleaned up.
private struct Shimmer: View {
    let vertical: Bool
    @State private var phase = 0.0
    var body: some View {
        let dots = ForEach(0..<3) { i in
            Circle().fill(Brand.barHoney).frame(width: 5, height: 5)
                .opacity(0.35 + 0.65 * max(0, cos((phase - Double(i) * 0.33) * .pi * 2)))
        }
        Group {
            if vertical { VStack(spacing: 5) { dots }.frame(width: 18) } else { HStack(spacing: 5) { dots }.frame(height: 18) }
        }
        .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

// MARK: - Drag overlay (dimmed screen, three drop targets, ghost handle)

@MainActor
@Observable
final class DragModel {
    var nearest: PillModel.Edge = .bottom
    var ghost: CGPoint = .zero  // SwiftUI coordinates within the screen (y down)
    var exiting = false
    var insets = EdgeInsets()   // work area inside the full screen frame
}

struct DragOverlayView: View {
    let model: DragModel

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, ins = model.insets
            let midY = (h + ins.top - ins.bottom) / 2
            ZStack(alignment: .topLeading) {
                Color(white: 0.09).opacity(0.6)
                zone(.bottom, size: CGSize(width: 124, height: 86),
                     center: CGPoint(x: w / 2, y: h - ins.bottom - 10 - 43))
                zone(.left, size: CGSize(width: 86, height: 124), center: CGPoint(x: ins.leading + 10 + 43, y: midY))
                zone(.right, size: CGSize(width: 86, height: 124),
                     center: CGPoint(x: w - ins.trailing - 10 - 43, y: midY))
                Circle().fill(Brand.barNight)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                    .overlay(Image(systemName: "waveform").font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.barHoney))
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    .position(model.ghost)
            }
        }
        .ignoresSafeArea()
        .opacity(model.exiting ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: model.exiting)
        .animation(.easeOut(duration: 0.15), value: model.nearest)
    }

    private func zone(_ edge: PillModel.Edge, size: CGSize, center: CGPoint) -> some View {
        let hot = model.nearest == edge
        return RoundedRectangle(cornerRadius: min(size.width, size.height) / 2)
            .fill(Color.white.opacity(hot ? 0.8 : 0.4))
            .frame(width: size.width, height: size.height)
            .scaleEffect(hot ? 1.08 : 1)
            .position(center)
    }
}

// MARK: - Windows

/// Hosting view that lets the container below receive every mouse event (for drag and click).
private final class PassthroughHostingView<V: View>: NSHostingView<V> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Handles hover, click and drag for the bar. Clicks outside the bar fall through to the app below.
private final class PillContainer: NSView {
    var onClick: () -> Void = {}
    var onDragBegan: () -> Void = {}
    var onDragMoved: (NSPoint) -> Void = { _ in }
    var onDragEnded: (NSPoint) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    var barRect: () -> NSRect = { .zero }
    private var downAt: NSPoint?
    private var dragged = false
    private var tracking: NSTrackingArea?

    private func onBar(_ p: NSPoint) -> Bool { barRect().insetBy(dx: -6, dy: -6).contains(p) }

    override func hitTest(_ point: NSPoint) -> NSView? { onBar(convert(point, from: superview)) ? self : nil }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) { onHover(onBar(convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt else { return }
        let now = NSEvent.mouseLocation
        if !dragged {
            guard hypot(now.x - downAt.x, now.y - downAt.y) >= 4 else { return }
            dragged = true
            onDragBegan()
        }
        onDragMoved(now)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        if dragged { onDragEnded(NSEvent.mouseLocation) } else { onClick() }
    }
}

@MainActor
final class PillWindow {
    let model = PillModel()
    private let panel: NSPanel
    private let container = PillContainer()
    private let host: NSHostingView<PillView>
    private var flashTask: Task<Void, Never>?
    private let drag = DragModel()
    private var overlay: NSPanel?
    private var dragScreen: NSScreen?
    var onClick: () -> Void = {}
    var onEdgeChanged: (PillModel.Edge) -> Void = { _ in }

    /// Panel sizes: wide and short at the bottom; narrow-ish and tall on the sides (room for a bubble).
    private func panelSize() -> NSSize {
        model.vertical ? NSSize(width: 330, height: 180) : NSSize(width: 360, height: 110)
    }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        host = PassthroughHostingView(rootView: PillView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        host.autoresizingMask = [.width, .height]
        container.frame = host.frame
        container.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container

        container.onClick = { [weak self] in self?.onClick() }
        container.onHover = { [weak self] h in
            guard let self, self.model.state == .idle, !self.model.dragging, self.model.hovering != h else { return }
            self.model.hovering = h
        }
        container.onDragBegan = { [weak self] in self?.beginDrag() }
        container.onDragMoved = { [weak self] p in self?.moveDrag(to: p) }
        container.onDragEnded = { [weak self] p in self?.endDrag(at: p) }
        container.barRect = { [weak self] in
            guard let self else { return .zero }
            let f = self.model.barFrame, h = self.container.bounds.height
            return NSRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)  // SwiftUI y-down → AppKit
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        // Follow the Dock: re-place when apps or Spaces change, and poll for full-screen toggles.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeIfDockChanged() }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeIfDockChanged() }
        }
    }

    func configure(edge: PillModel.Edge, showWhenIdle: Bool, keyName: String) {
        if configured && edge != model.edge && !model.dragging { along = 0.5 }  // picked in Settings: start centred
        configured = true
        model.edge = edge
        model.showWhenIdle = showWhenIdle
        model.keyName = keyName
        place(animated: false)
        panel.orderFrontRegardless()
    }

    func show(_ state: PillModel.State) {
        flashTask?.cancel()
        if state != .idle { model.hovering = false }
        model.state = state
        panel.orderFrontRegardless()
    }

    func flash(_ text: String, seconds: Double = 1.6) {
        show(.message(text))
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, case .message(text) = model.state else { return }
            model.state = .idle
        }
    }

    // MARK: Drag

    private func beginDrag() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        dragScreen = screen
        model.hovering = false
        model.dragging = true
        let f = screen.frame, v = screen.visibleFrame
        drag.insets = EdgeInsets(top: f.maxY - v.maxY, leading: v.minX - f.minX,
                                 bottom: (model.edge == .bottom && Self.dockVisible() ? v.minY : f.minY) - f.minY,
                                 trailing: f.maxX - v.maxX)
        drag.exiting = false
        let o = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        o.isOpaque = false
        o.backgroundColor = .clear
        o.hasShadow = false
        o.level = .statusBar
        o.ignoresMouseEvents = true
        o.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        o.contentView = NSHostingView(rootView: DragOverlayView(model: drag))
        o.setFrame(f, display: false)
        o.alphaValue = 0
        o.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; o.animator().alphaValue = 1 }
        overlay = o
        panel.orderFrontRegardless()  // keep the bar's window above for event routing
    }

    private func local(_ p: NSPoint) -> CGPoint {
        guard let f = dragScreen?.frame else { return .zero }
        return CGPoint(x: p.x - f.minX, y: f.maxY - p.y)
    }

    /// The edge closest to the pointer, and where on that edge the bar's centre lands (overlay coordinates):
    /// the bar can sit anywhere along an edge, like Wispr's.
    private func nearest(_ p: CGPoint) -> (PillModel.Edge, CGPoint) {
        guard let f = dragScreen?.frame else { return (.bottom, p) }
        let ins = drag.insets, w = f.width, h = f.height
        let dBottom = h - ins.bottom - p.y, dLeft = p.x - ins.leading, dRight = w - ins.trailing - p.x
        let x = min(max(p.x, ins.leading + 70), w - ins.trailing - 70)
        let y = min(max(p.y, ins.top + 70), h - ins.bottom - 70)
        if dBottom <= dLeft && dBottom <= dRight { return (.bottom, CGPoint(x: x, y: h - ins.bottom - 23)) }
        return dLeft <= dRight ? (.left, CGPoint(x: ins.leading + 18, y: y)) : (.right, CGPoint(x: w - ins.trailing - 18, y: y))
    }

    private var configured = false

    /// Position along the current edge, 0…1 (left→right on the bottom, top→bottom on the sides). Saved.
    private var along: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "barAlong")
        return v > 0 ? v : 0.5
    }() {
        didSet { UserDefaults.standard.set(Double(along), forKey: "barAlong") }
    }

    private func moveDrag(to p: NSPoint) {
        let q = local(p)
        drag.ghost = q
        drag.nearest = nearest(q).0
    }

    private func endDrag(at p: NSPoint) {
        let (edge, target) = nearest(local(p))
        if let f = dragScreen?.frame {
            let ins = drag.insets
            along = edge == .bottom
                ? (target.x - ins.leading) / max(1, f.width - ins.leading - ins.trailing)
                : (target.y - ins.top) / max(1, f.height - ins.top - ins.bottom)
        }
        withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.3)) { drag.ghost = target }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            model.edge = edge
            place(on: dragScreen, animated: false)
            model.dragging = false
            drag.exiting = true
            onEdgeChanged(edge)
            try? await Task.sleep(for: .milliseconds(200))
            overlay?.orderOut(nil)
            overlay = nil
        }
    }

    // MARK: Placement

    private var lastDockVisible: Bool?

    /// Is the Dock taking space at the bottom right now? Not if it auto-hides, and not over a full-screen app.
    static func dockVisible() -> Bool {
        if UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") == true { return false }
        if let app = NSWorkspace.shared.frontmostApplication {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            var w: CFTypeRef?, fs: CFTypeRef?
            if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &w) == .success, let w,
               AXUIElementCopyAttributeValue(w as! AXUIElement, "AXFullScreen" as CFString, &fs) == .success,
               (fs as? Bool) == true { return false }
        }
        return true
    }

    private func placeIfDockChanged() {
        guard model.edge == .bottom, !model.dragging else { return }
        if Self.dockVisible() != lastDockVisible { place() }
    }

    private func place(on screen: NSScreen? = nil, animated: Bool = true) {
        guard let screen = screen ?? panel.screen ?? NSScreen.main else { return }
        let f = screen.visibleFrame, s = panelSize()
        let dock = Self.dockVisible()
        lastDockVisible = dock
        // Above the Dock when it's showing; otherwise right down at the bottom edge.
        let bottom = dock ? f.minY : screen.frame.minY
        let origin: NSPoint
        // Wherever it was dropped along the edge, kept fully on screen.
        let cx = min(max(f.minX + along * f.width - s.width / 2, f.minX + 8), f.maxX - s.width - 8)
        let cy = min(max(f.maxY - along * f.height - s.height / 2, f.minY + 8), f.maxY - s.height - 8)
        switch model.edge {
        case .bottom: origin = NSPoint(x: cx, y: bottom)
        case .left: origin = NSPoint(x: f.minX, y: cy)
        case .right: origin = NSPoint(x: f.maxX - s.width, y: cy)
        }
        let frame = NSRect(origin: origin, size: s)
        guard animated else { panel.setFrame(frame, display: true); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }
}
