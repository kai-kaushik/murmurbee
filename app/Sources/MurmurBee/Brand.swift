import AppKit
import CoreText
import SwiftUI

/// MurmurBee's look: night background, linen text, honey accent, Sora wordmark (brand/, site/).
enum Brand {
    static let night = Color(red: 0x16 / 255, green: 0x13 / 255, blue: 0x0F / 255)
    static let surface = Color(red: 0x20 / 255, green: 0x1B / 255, blue: 0x16 / 255)
    static let raised = Color(red: 0x2A / 255, green: 0x23 / 255, blue: 0x1B / 255)
    static let border = Color(red: 0x3A / 255, green: 0x32 / 255, blue: 0x2A / 255)
    static let linen = Color(red: 0xF7 / 255, green: 0xEF / 255, blue: 0xE0 / 255)
    static let sand = Color(red: 0xC9 / 255, green: 0xBB / 255, blue: 0xA3 / 255)
    static let honey = Color(red: 0xF8 / 255, green: 0xBE / 255, blue: 0x34 / 255)
    static let nsNight = NSColor(red: 0x16 / 255, green: 0x13 / 255, blue: 0x0F / 255, alpha: 1)

    static func resource(_ path: String) -> URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent(path)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Full-colour bee for windows.
    static let bee: NSImage? = resource("brand/bee.png").flatMap(NSImage.init(contentsOf:))

    /// Monochrome bee for the menu bar (template, so macOS tints it).
    static let menuBarIcon: NSImage? = {
        guard let url = resource("brand/menubar.png"), let img = NSImage(contentsOf: url) else { return nil }
        if let url2 = resource("brand/menubar@2x.png"), let rep = NSImage(contentsOf: url2)?.representations.first {
            rep.size = NSSize(width: 18, height: 18)
            img.addRepresentation(rep)
        }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }()

    /// Registers the bundled Sora font once; falls back to the system font if it's missing.
    static let soraAvailable: Bool = {
        guard let url = resource("fonts/Sora.ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func sora(_ size: CGFloat) -> Font {
        soraAvailable ? .custom("Sora", size: size).weight(.semibold) : .system(size: size, weight: .semibold)
    }
}

/// "Murmur" + honey "Bee".
struct Wordmark: View {
    var size: CGFloat = 24
    var body: some View {
        (Text("Murmur").foregroundStyle(Brand.linen) + Text("Bee").foregroundStyle(Brand.honey))
            .font(Brand.sora(size))
            .kerning(-size * 0.04)
    }
}

extension View {
    /// Dark MurmurBee window chrome for SwiftUI content.
    func brandWindow() -> some View {
        self.preferredColorScheme(.dark)
            .tint(Brand.honey)
            .foregroundStyle(Brand.linen)
            .background(Brand.night)
    }
}
