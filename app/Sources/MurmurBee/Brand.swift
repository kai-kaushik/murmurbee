import AppKit
import CoreText
import SwiftUI

/// MurmurBee's look: night background, linen text, honey accent, Sora wordmark (brand/, site/).
enum Brand {
    /// A colour with a light and a dark value, resolved against the view's appearance.
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    // Window colours: night/linen in dark mode, paper/ink in light mode.
    static let nsNight = dynamic(0xFBF7F0, 0x16130F)
    static let night = Color(nsColor: nsNight)                       // page background
    static let surface = Color(nsColor: dynamic(0xF3ECE0, 0x201B16)) // sidebar, cards
    static let raised = Color(nsColor: dynamic(0xE9E0D0, 0x2A231B))  // hover, inputs, selected
    static let border = Color(nsColor: dynamic(0xE2D7C4, 0x3A322A))
    static let linen = Color(nsColor: dynamic(0x1F1A14, 0xF7EFE0))   // primary text
    static let sand = Color(nsColor: dynamic(0x6A5B45, 0xC9BBA3))    // secondary text
    /// Honey as text and marks: deeper gold on paper so it stays readable.
    static let honey = Color(nsColor: dynamic(0xB9791A, 0xF8BE34))
    /// Honey as a fill (buttons, switches): the same bright honey in both modes, with dark text on it.
    static let honeyFill = Color(red: 0xF8 / 255, green: 0xBE / 255, blue: 0x34 / 255)
    static let ink = Color(red: 0x16 / 255, green: 0x13 / 255, blue: 0x0F / 255)

    // The flow bar is always dark, like the real product shot on the website.
    static let barNight = Color(red: 0x16 / 255, green: 0x13 / 255, blue: 0x0F / 255)
    static let barHoney = honeyFill

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
        self.tint(Brand.honeyFill)
            .foregroundStyle(Brand.linen)
            .background(Brand.night)
    }
}
