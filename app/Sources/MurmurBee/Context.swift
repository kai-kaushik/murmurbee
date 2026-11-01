import AppKit
import ApplicationServices

/// What the app knows at key-down. Read through Accessibility; every field degrades to empty quietly.
struct ContextSnapshot: Sendable {
    var bundleId = ""
    var appName = ""
    var appType = "general"
    var windowTitle = ""
    var beforeCursor = ""
    var selectedText = ""
    var afterCursor = ""
    /// Browser page (host/first path segment), read from the web area's AXURL. Empty outside browsers.
    var url = ""
    var isSecureField = false
    var captureUnavailable = false
    var pid: pid_t = 0

    /// App types, matching the labels the cleanup model was trained with.
    static let appTypes: [String: (String, String)] = [
        "com.anthropic.claudefordesktop": ("Claude", "AI assistant prompt"),
        "com.openai.chat": ("ChatGPT", "AI assistant prompt"),
        "com.tinyspeck.slackmacgap": ("Slack", "work chat"),
        "com.apple.MobileSMS": ("Messages", "personal chat"),
        "net.whatsapp.WhatsApp": ("WhatsApp", "personal chat"),
        "com.apple.mail": ("Mail", "email"),
        "com.superhuman.electron": ("Superhuman", "email"),
        "com.google.Chrome": ("Chrome", "browser"),
        "com.microsoft.VSCode": ("VS Code", "code editor"),
        "com.todesktop.230313mzl4w4u92": ("Cursor", "code editor"),
    ]

    @MainActor
    static func capture() -> ContextSnapshot {
        var c = ContextSnapshot()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var unresponsive = false
        func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
            Self.attr(element, name, deadline: deadline) { unresponsive = true }
        }
        // Check password fields before optional context can exhaust the accessibility budget.
        let system = AXUIElementCreateSystemWide()
        let focused: AXUIElement? = attr(system, kAXFocusedUIElementAttribute)
        if let focused {
            let subrole: String = attr(focused, kAXSubroleAttribute) ?? ""
            c.isSecureField = subrole == (kAXSecureTextFieldSubrole as String)
            if c.isSecureField { return c }
        }
        if unresponsive { c.captureUnavailable = true; return c }
        if let app = NSWorkspace.shared.frontmostApplication {
            c.bundleId = app.bundleIdentifier ?? ""
            c.pid = app.processIdentifier
            let known = appTypes[c.bundleId]
            c.appName = known?.0 ?? app.localizedName ?? c.bundleId.split(separator: ".").last.map(String.init) ?? ""
            c.appType = known?.1 ?? "general"
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            if let window: AXUIElement = attr(axApp, kAXFocusedWindowAttribute) {
                c.windowTitle = attr(window, kAXTitleAttribute) ?? ""
            }
            // Web mail in a browser is email, like the training data's mail.google.com rows.
            if c.appType == "browser" || known == nil {
                if c.windowTitle.contains("Gmail") { (c.appName, c.appType) = ("Gmail", "email") }
                else if c.windowTitle.contains("Outlook") { (c.appName, c.appType) = ("Outlook", "email") }
            }
        }
        guard let focused else { return c }
        c.selectedText = attr(focused, kAXSelectedTextAttribute) ?? ""
        if let value: String = attr(focused, kAXValueAttribute), let range = selectedRange(focused, deadline: deadline) {
            let ns = value as NSString
            let end = min(range.location, ns.length)
            let start = max(0, end - 200)
            c.beforeCursor = ns.substring(with: NSRange(location: start, length: end - start))
            let afterStart = min(range.location + range.length, ns.length)
            c.afterCursor = ns.substring(with: NSRange(location: afterStart, length: min(120, ns.length - afterStart)))
        }
        c.url = webURL(from: focused, deadline: deadline)
        return c
    }

    /// Walk up from the focused element to the browser's web area and read its URL, trimmed like training data.
    private static func webURL(from el: AXUIElement, deadline: TimeInterval) -> String {
        var node: AXUIElement? = el
        for _ in 0..<25 {
            guard let n = node else { break }
            let role: String = attr(n, kAXRoleAttribute, deadline: deadline) ?? ""
            if role == "AXWebArea" {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return "" }
                var v: CFTypeRef?
                guard AXUIElementCopyAttributeValue(n, "AXURL" as CFString, &v) == .success, let v else { return "" }
                let raw = (v as? URL)?.absoluteString ?? (v as? String) ?? ""
                return cleanURL(raw)
            }
            node = attr(n, kAXParentAttribute, deadline: deadline)
        }
        return ""
    }

    /// Mirrors prompt_v3.clean_url: drop scheme, query and fragment; keep host + first path segment, ≤ 60 chars.
    static func cleanURL(_ url: String) -> String {
        guard !url.isEmpty, url != "about:blank" else { return "" }
        var u = url.replacingOccurrences(of: #"^[a-z]+://"#, with: "", options: .regularExpression)
        u = String(u.split(separator: "?", maxSplits: 1).first ?? "")
        u = String(u.split(separator: "#", maxSplits: 1).first ?? "")
        let parts = u.split(separator: "/", omittingEmptySubsequences: false)
        return String(parts.prefix(2).joined(separator: "/").prefix(60))
    }

    /// Region and language ("en-GB"), UTC offset ("UTC+01:00") and local time, as in the training data.
    static func clock(_ now: Date = Date()) -> (locale: String, tz: String, time: String) {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier
        let locale = region.map { "\(lang)-\($0)" } ?? lang
        let secs = TimeZone.current.secondsFromGMT(for: now)
        let m = abs(secs) / 60
        let tz = String(format: "UTC%@%02d:%02d", secs >= 0 ? "+" : "-", m / 60, m % 60)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE dd MMM yyyy HH:mm"
        return (locale, tz, f.string(from: now))
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String, deadline: TimeInterval,
                                onTimeout: () -> Void = {}) -> T? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { onTimeout(); return nil }
        AXUIElementSetMessagingTimeout(el, Float(min(0.05, remaining)))
        var v: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(el, name as CFString, &v)
        if result == .cannotComplete { onTimeout() }
        guard result == .success else { return nil }
        return v as? T
    }

    private static func selectedRange(_ el: AXUIElement, deadline: TimeInterval) -> CFRange? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }
        AXUIElementSetMessagingTimeout(el, Float(min(0.05, remaining)))
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let value = v, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
}
