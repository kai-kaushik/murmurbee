// Renders the DMG window background (660x400 pt, 1x and 2x) into app/Resources/dmg/.
// Usage: swift scripts/make_dmg_background.swift   (from the repo root)
import AppKit
import CoreText

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let out = root.appendingPathComponent("app/Resources/dmg")
CTFontManagerRegisterFontsForURL(root.appendingPathComponent("app/Resources/fonts/Sora.ttf") as CFURL, .process, nil)

let night = NSColor(srgbRed: 0x16/255, green: 0x13/255, blue: 0x0F/255, alpha: 1)
let raised = NSColor(srgbRed: 0x22/255, green: 0x1D/255, blue: 0x17/255, alpha: 1)
let linen = NSColor(srgbRed: 0xF7/255, green: 0xEF/255, blue: 0xE0/255, alpha: 1)
let sand = NSColor(srgbRed: 0xC9/255, green: 0xBB/255, blue: 0xA3/255, alpha: 1)
let honey = NSColor(srgbRed: 0xF8/255, green: 0xBE/255, blue: 0x34/255, alpha: 1)
let W: CGFloat = 660, H: CGFloat = 400

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Background with a soft lighter band behind the two icons.
    NSGradient(starting: raised, ending: night)!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Wordmark + instruction, top centre (y is from the bottom).
    let sora = NSFont(name: "Sora", size: 26) ?? .systemFont(ofSize: 26, weight: .semibold)
    let mark = NSMutableAttributedString(string: "Murmur", attributes: [.font: sora, .foregroundColor: linen, .kern: -1])
    mark.append(NSAttributedString(string: "Bee", attributes: [.font: sora, .foregroundColor: honey, .kern: -1]))
    let ms = mark.size()
    mark.draw(at: NSPoint(x: (W - ms.width) / 2, y: H - 62))
    let hint = NSAttributedString(string: "Drag MurmurBee into Applications",
                                  attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: sand])
    let hs = hint.size()
    hint.draw(at: NSPoint(x: (W - hs.width) / 2, y: H - 92))

    // Dotted honey trail from the app (x 180) to Applications (x 480), icons centred at y = 190 from the top.
    let y = H - 190
    let trail = NSBezierPath()
    trail.move(to: NSPoint(x: 262, y: y + 6))
    trail.curve(to: NSPoint(x: 392, y: y + 6), controlPoint1: NSPoint(x: 300, y: y + 46), controlPoint2: NSPoint(x: 354, y: y + 46))
    trail.lineWidth = 3.2
    trail.lineCapStyle = .round
    trail.setLineDash([0.1, 10], count: 2, phase: 0)
    honey.setStroke()
    trail.stroke()
    // Arrow head, aligned with the end of the curve.
    let tip = NSPoint(x: 394, y: y + 4)
    let dir = (x: 38.0, y: -40.0), len = (dir.x * dir.x + dir.y * dir.y).squareRoot()
    let (ux, uy) = (dir.x / len, dir.y / len)
    func wing(_ deg: Double) -> NSPoint {
        let a = deg * .pi / 180, bx = -ux * 13, by = -uy * 13
        return NSPoint(x: tip.x + bx * cos(a) - by * sin(a), y: tip.y + bx * sin(a) + by * cos(a))
    }
    let head = NSBezierPath()
    head.move(to: wing(32)); head.line(to: tip); head.line(to: wing(-32))
    head.lineWidth = 3
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    let foot = NSAttributedString(string: "Free and open source · nothing leaves your Mac",
                                  attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: sand.withAlphaComponent(0.75)])
    let fs = foot.size()
    foot.draw(at: NSPoint(x: (W - fs.width) / 2, y: 28))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    try! render(scale: scale).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
print("ok")
