// Renders MurmurBee's app icon, menu-bar template and in-app bee from brand/*.svg.
// Usage: swift scripts/make_icons.swift   (from the repo root)
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let mark = NSImage(contentsOf: root.appendingPathComponent("brand/murmurbee-mark.svg"))!
let bee = NSImage(contentsOf: root.appendingPathComponent("brand/murmurbee-bee.svg"))!
let out = root.appendingPathComponent("app/Resources/brand")
let night = NSColor(red: 0x16/255, green: 0x13/255, blue: 0x0F/255, alpha: 1)
let raised = NSColor(red: 0x2A/255, green: 0x23/255, blue: 0x1B/255, alpha: 1)

func render(_ px: Int, _ draw: (CGRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func save(_ rep: NSBitmapImageRep, _ url: URL) { try! rep.representation(using: .png, properties: [:])!.write(to: url) }

// App icon: Big Sur grid (824/1024 squircle-ish rounded rect), night gradient, the full mark.
func icon(_ px: Int) -> NSBitmapImageRep {
    render(px) { r in
        let s = CGFloat(px) / 1024
        let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 20 * s; shadow.shadowOffset = NSSize(width: 0, height: -10 * s); shadow.set()
        night.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: raised, ending: night)!.draw(in: path, angle: -90)
        let w = 760 * s, h = w * mark.size.height / mark.size.width
        mark.draw(in: CGRect(x: tile.midX - w / 2, y: tile.midY - h / 2 - 10 * s, width: w, height: h))
    }
}
let iconset = root.appendingPathComponent("app/build.noindex/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    save(icon(base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    save(icon(base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

// In-app bee (full colour) for windows.
save(render(256) { r in bee.draw(in: r) }, out.appendingPathComponent("bee.png"))

// Menu-bar template: a simple bee silhouette drawn on an 18 pt grid (stripes, eye and gaps cut out).
for (px, name) in [(18, "menubar.png"), (36, "menubar@2x.png")] {
    let rep = render(px) { r in
        let k = CGFloat(px) / 18
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * k, y: y * k, width: w * k, height: h * k) }
        let ctx = NSGraphicsContext.current!
        NSColor.black.setFill(); NSColor.black.setStroke()
        NSBezierPath(ovalIn: rect(1, 2.5, 11.5, 9)).fill()                       // body
        NSBezierPath(ovalIn: rect(11.2, 4.4, 6.2, 6.2)).fill()                    // head
        let wing = NSBezierPath(ovalIn: rect(3, 10.6, 6.4, 5.2)); wing.fill()     // wing
        ctx.compositingOperation = .clear
        NSBezierPath(rect: rect(4.6, 0, 1.5, 11)).fill()                           // stripes
        NSBezierPath(rect: rect(7.6, 0, 1.5, 11)).fill()
        let gap = NSBezierPath(ovalIn: rect(11.2, 4.4, 6.2, 6.2)); gap.lineWidth = 1.2 * k; gap.stroke()
        let wgap = NSBezierPath(ovalIn: rect(3, 10.6, 6.4, 5.2)); wgap.lineWidth = 1.2 * k; wgap.stroke()
        NSBezierPath(ovalIn: rect(14.6, 7.6, 1.4, 1.4)).fill()                    // eye
        ctx.compositingOperation = .sourceOver
        NSBezierPath(ovalIn: rect(11.8, 5.0, 5.0, 5.0)).fill()                    // head again, inside its gap
        NSBezierPath(ovalIn: rect(3.6, 11.2, 5.2, 4.0)).fill()                    // wing again, inside its gap
        let ant = NSBezierPath(); ant.move(to: NSPoint(x: 15 * k, y: 9.6 * k))
        ant.curve(to: NSPoint(x: 16.4 * k, y: 15.6 * k), controlPoint1: NSPoint(x: 15.6 * k, y: 12 * k), controlPoint2: NSPoint(x: 15.6 * k, y: 14.6 * k))
        ant.lineWidth = 1.1 * k; ant.lineCapStyle = .round; ant.stroke()
        ctx.compositingOperation = .clear
        NSBezierPath(ovalIn: rect(14.6, 7.6, 1.4, 1.4)).fill()
        ctx.compositingOperation = .sourceOver
    }
    save(rep, out.appendingPathComponent(name))
}
print("ok")
