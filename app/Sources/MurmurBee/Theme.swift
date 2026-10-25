import AppKit
import QuartzCore

/// Light / dark / system appearance, switched with the same radial wipe as the website: the old look is
/// snapshotted, the new appearance applied underneath, and the snapshot dissolves through a soft-edged circle
/// that grows from where you clicked.
@MainActor
enum Theme {
    enum Mode: String, CaseIterable { case system, light, dark }

    static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }

    /// Applies the saved mode without animation (at launch).
    static func applySaved() { apply(mode) }

    private static func apply(_ m: Mode) {
        NSApp.appearance = switch m {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// Flips between light and dark, wiping from the mouse pointer in the key window.
    static func toggle() { set(isDark ? .light : .dark) }

    static func set(_ m: Mode) {
        UserDefaults.standard.set(m.rawValue, forKey: "appearance")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion, let window = NSApp.keyWindow, let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            apply(m)
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        let snapshot = NSImage(size: content.bounds.size)
        snapshot.addRepresentation(rep)

        let overlay = NSImageView(frame: content.bounds)
        overlay.image = snapshot
        overlay.imageScaling = .scaleAxesIndependently
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        content.addSubview(overlay)

        apply(m)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()

        // Origin: the pointer if it's inside the window, else the window's centre.
        let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        var origin = overlay.convert(mouse, from: nil)
        if !overlay.bounds.contains(origin) { origin = NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY) }
        let b = overlay.bounds
        let far = [NSPoint(x: b.minX, y: b.minY), NSPoint(x: b.maxX, y: b.minY),
                   NSPoint(x: b.minX, y: b.maxY), NSPoint(x: b.maxX, y: b.maxY)]
            .map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? 0
        let edge: CGFloat = 80
        let radius = far + edge

        // Mask: transparent inside a growing circle (the new look shows through), opaque outside, soft edge.
        let mask = CAGradientLayer()
        mask.type = .radial
        mask.frame = CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)
        mask.startPoint = CGPoint(x: 0.5, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 1)
        mask.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor]
        let e = Double(edge / radius)
        mask.locations = [0, 0, NSNumber(value: e)]
        // A bigger mask than the window so its corners stay opaque until the circle reaches them.
        let cover = CALayer()
        cover.frame = overlay.bounds
        cover.addSublayer(mask)
        overlay.layer?.mask = cover

        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [0, 0, e]
        anim.toValue = [0, 1, 1]
        anim.duration = 0.7
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { overlay.removeFromSuperview() }
        mask.add(anim, forKey: "wipe")
        CATransaction.commit()
    }
}
