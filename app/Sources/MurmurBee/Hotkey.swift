import AppKit
import CoreGraphics
import Synchronization

/// Global event tap for hold-to-talk.
/// Holding the chosen modifier (Fn or Right Option) starts a dictation; releasing it ends it.
/// Esc while held cancels. Any other key pressed while held means it was a shortcut, so we cancel too.
///
/// The tap filters: presses of the chosen key are consumed, so other things bound to it (Apple Dictation on a
/// double fn, an app's double-Option shortcut) don't fire as well. It runs on its own thread and only compares a
/// key code there, so typing is never held up by the main thread. Without Accessibility it falls back to
/// listening only, as before.
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

    /// The key code the tap thread consumes. Settings updates it when the hold key changes.
    nonisolated static let consumedKeyCode = Atomic<Int64>(-1)

    var key: Key { Settings.shared.holdKey }
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Esc at any time (hands-free mode has no key held).
    var onEscape: () -> Void = {}

    private let box = TapBox()
    var isListening: Bool { box.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    /// True when the chosen key is consumed (Accessibility granted), false when only listening.
    private(set) var isFiltering = false
    private var isDown = false

    /// Returns false if macOS refused the tap (Input Monitoring not granted yet).
    func start() -> Bool {
        Self.consumedKeyCode.store(key.keyCode, ordering: .relaxed)
        box.onEvent = { [weak self] type, keyCode, flags in
            MainActor.assumeIsolated { self?.handle(type: type, keyCode: keyCode, flags: flags) }
        }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(box).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let box = Unmanaged<TapBox>.fromOpaque(userInfo!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = box.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            DispatchQueue.main.async { box.onEvent(type, keyCode, flags) }
            if box.filtering, type == .flagsChanged,
               keyCode == Hotkey.consumedKeyCode.load(ordering: .relaxed) {
                return nil  // ours: don't also trigger Apple Dictation or another app's shortcut
            }
            return Unmanaged.passUnretained(event)
        }
        // Earliest tap that filters (needs Accessibility), then a session-level filter, then listen-only.
        let attempts: [(CGEventTapLocation, CGEventTapOptions)] =
            [(.cghidEventTap, .defaultTap), (.cgSessionEventTap, .defaultTap), (.cgSessionEventTap, .listenOnly)]
        for (location, options) in attempts {
            guard let tap = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: options,
                                              eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: me)
            else { continue }
            box.tap = tap
            box.filtering = options == .defaultTap
            isFiltering = box.filtering
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            let thread = Thread {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                CFRunLoopRun()
            }
            thread.name = "MurmurBee hotkey tap"
            thread.qualityOfService = .userInteractive
            thread.start()
            return true
        }
        return false
    }

    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch type {
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

/// State shared with the tap thread. `tap` and `filtering` are set once before the thread starts.
private final class TapBox: @unchecked Sendable {
    var tap: CFMachPort?
    var filtering = false
    var onEvent: @Sendable (CGEventType, Int64, CGEventFlags) -> Void = { _, _, _ in }
}
