import AppKit
import CoreGraphics

/// Listen-only global event tap for hold-to-talk.
/// Holding the chosen modifier (Fn or Right Option) starts a dictation; releasing it ends it.
/// Esc while held cancels. Any other key pressed while held means it was a shortcut, so we cancel too.
@MainActor
final class Hotkey {
    enum Key: String, CaseIterable {
        case fn = "Fn (🌐)"
        case rightOption = "Right Option"

        var keyCode: Int64 { self == .fn ? 63 : 61 }
        /// Short label for tooltips, like Wispr's "Dictate fn".
        var short: String { self == .fn ? "fn" : "right ⌥" }
        var flag: CGEventFlags { self == .fn ? .maskSecondaryFn : .maskAlternate }
    }

    var key: Key { Settings.shared.holdKey }
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Esc at any time (hands-free mode has no key held).
    var onEscape: () -> Void = {}

    private var tap: CFMachPort?
    var isListening: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    private var isDown = false

    /// Returns false if macOS refused the tap (Input Monitoring not granted yet).
    func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                let hotkey = Unmanaged<Hotkey>.fromOpaque(userInfo!).takeUnretainedValue()
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                MainActor.assumeIsolated { hotkey.handle(type: type, keyCode: keyCode, flags: flags) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: me)
        else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged where keyCode == key.keyCode:
            let pressed = flags.contains(key.flag)
            if pressed && !isDown {
                isDown = true
                onDown()
            } else if !pressed && isDown {
                isDown = false
                onUp()
            }
        case .keyDown where isDown:
            isDown = false
            onCancel()  // Esc, or a shortcut like Fn+arrow: either way, not a dictation
        case .keyDown where keyCode == 53:
            onEscape()
        default:
            break
        }
    }
}
