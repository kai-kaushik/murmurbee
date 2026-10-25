import AppKit
import ApplicationServices
import CoreGraphics

/// Pastes text at the cursor immediately, then verifies in the background.
/// 1. Put the text on the clipboard and send a clean ⌘V (no other modifiers leaking in).
/// 2. Check through Accessibility whether the focused field changed.
/// 3. If it clearly didn't, insert through Accessibility instead; if that fails too, leave the text on
///    the clipboard. Otherwise restore the user's previous clipboard.
@MainActor
final class Inserter {
    enum Method: String { case paste, axInsert = "ax_insert", clipboardOnly = "clipboard_only", unverified }
    struct Outcome {
        var method: Method
        var confirmed: Bool
        /// The field we pasted into and its contents just after the paste, for edit capture.
        var field: AXUIElement? = nil
        var fieldAfter: String? = nil
    }

    /// Sends the paste right away and returns; `verified` is called later with the outcome.
    func insert(_ text: String, verified: @escaping @MainActor (Outcome) -> Void) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let d = item.data(forType: type) { copy.setData(d, forType: type) } }
            return copy
        } ?? []
        let field = Self.focusedElement()
        let before = field.flatMap(Self.value)

        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount
        Self.pressCmdV()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            var outcome = Outcome(method: .unverified, confirmed: false)
            if let field, let before {
                let after = Self.value(field) ?? before
                if after != before {
                    outcome = Outcome(method: .paste, confirmed: true, field: field, fieldAfter: after)
                } else if Self.axInsert(text, into: field), (Self.value(field) ?? before) != before {
                    outcome = Outcome(method: .axInsert, confirmed: true, field: field, fieldAfter: Self.value(field))
                } else {
                    verified(Outcome(method: .clipboardOnly, confirmed: false))
                    return  // leave our text on the clipboard so ⌘V works by hand
                }
            }
            // Restore the user's clipboard, unless something else has written to it since.
            try? await Task.sleep(for: .milliseconds(200))
            if pb.changeCount == ourChange {
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
            verified(outcome)
        }
    }

    /// ⌘V from a private event source, so physical modifier state (e.g. a just-released Option) can't leak in.
    static func pressCmdV() {
        let src = CGEventSource(stateID: .privateState)
        let cmd: CGKeyCode = 55, v: CGKeyCode = 9
        let events = [
            CGEvent(keyboardEventSource: src, virtualKey: cmd, keyDown: true),
            CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
            CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false),
            CGEvent(keyboardEventSource: src, virtualKey: cmd, keyDown: false),
        ]
        for (i, e) in events.enumerated() {
            e?.flags = i < 3 ? .maskCommand : []
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func focusedElement() -> AXUIElement? {
        var v: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &v) == .success
        else { return nil }
        return (v as! AXUIElement)
    }

    static func value(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// Replaces the selection (or inserts at the caret) through Accessibility. Works in most native fields.
    private static func axInsert(_ text: String, into el: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
}
