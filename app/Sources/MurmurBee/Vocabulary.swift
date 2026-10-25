import AppKit
import ApplicationServices

/// Words worth spelling right: the user's dictionary file plus names visible in the focused window.
/// Like Wispr's dictionary_context + ax_context, sent to the cleanup model as `vocab:`.
enum Vocabulary {
    static let file = Store.directory.appendingPathComponent("dictionary.txt")

    /// One term per line; '#' starts a comment. Seeded from the Wispr export on first run.
    static func dictionary() -> [String] {
        if !FileManager.default.fileExists(atPath: file.path),
           let seed = Bundle.main.url(forResource: "dictionary-seed", withExtension: "txt") {
            try? FileManager.default.copyItem(at: seed, to: file)
        }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Terms for one chunk: on-screen names first, then dictionary terms that sound like something in the
    /// transcript. Capped like training (PromptV2.maxVocab).
    static func select(raw: String, screen: [String], dictionary: [String]) -> [String] {
        let words = raw.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        func near(_ term: String) -> Bool {
            let t = term.lowercased().filter { $0.isLetter || $0.isNumber }
            guard t.count >= 3 else { return false }
            let n = term.split(separator: " ").count
            for i in 0..<max(words.count - n + 1, 0) {
                let w = words[i..<(i + n)].joined()
                if w == t || (w.first == t.first && similarity(w, t) >= 0.6) { return true }
            }
            return false
        }
        var out: [String] = []
        for t in screen.prefix(8) + dictionary.filter(near) where !out.contains(t) { out.append(t) }
        return Array(out.prefix(PromptV2.maxVocab))
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[b.count]) / Double(max(a.count, b.count))
    }

    /// Proper-noun-looking words from the screen, nearest to the cursor first. We start at the focused text
    /// field and walk outward through its ancestors (in Gmail: the compose window's To field, subject and
    /// thread before the inbox list and menus), so the people and things you're writing about rank first.
    static func screenNames(pid: pid_t) -> [String] {
        var v: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        var start: AXUIElement?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &v) == .success, let v {
            start = (v as! AXUIElement)
        } else if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString,
                                                &v) == .success, let v {
            start = (v as! AXUIElement)
        }
        guard let start else { return [] }

        let skipRoles: Set<String> = ["AXMenuBar", "AXMenu", "AXMenuItem", "AXToolbar", "AXScrollBar", "AXTabGroup"]
        var scores: [String: Double] = [:]
        var visitedTotal = 0
        let deadline = Date().addingTimeInterval(0.12)
        var level = 0
        var node: AXUIElement? = start
        var done = Set<CFHashCode>()
        while let ancestor = node, level <= 8, Date() < deadline {
            let weight = Double(9 - level)
            var stack = [ancestor]
            var visited = 0
            while let el = stack.popLast(), visited < 150, visitedTotal < 900, Date() < deadline {
                let h = CFHash(el)
                if done.contains(h) { continue }
                done.insert(h)
                visited += 1
                visitedTotal += 1
                var r: CFTypeRef?
                let role = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r) == .success
                    ? (r as? String ?? "") : ""
                if skipRoles.contains(role) { continue }
                var text = ""
                for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    var s: CFTypeRef?
                    if AXUIElementCopyAttributeValue(el, attr as CFString, &s) == .success, let str = s as? String,
                       str.count < 600 { text += " " + str }
                }
                // Buttons and labels are mostly UI ("Send", "Inactive"); keep them only if they hold an email address.
                let isUILabel = role == "AXButton" || role == "AXCheckBox" || role == "AXPopUpButton"
                if !isUILabel || text.contains("@") {
                    for n in properNouns(in: text, limit: 30) { scores[n, default: 0] += weight }
                }
                var kids: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
                   let arr = kids as? [AXUIElement] { stack.append(contentsOf: arr.prefix(40)) }
            }
            var parent: CFTypeRef?
            node = AXUIElementCopyAttributeValue(ancestor, kAXParentAttribute as CFString, &parent) == .success
                ? (parent as! AXUIElement) : nil
            level += 1
        }
        return scores.sorted { $0.value > $1.value }.prefix(10).map(\.key)
    }

    static let stop: Set<String> = ["The", "This", "That", "And", "But", "For", "You", "Your", "With", "From", "What",
        "When", "Where", "Which", "Who", "How", "Why", "Yes", "Not", "All", "New", "Open", "Close", "Search", "Edit",
        "View", "File", "Help", "Window", "Today", "Yesterday", "Reply", "Forward", "Send", "Inbox", "Settings",
        "Home", "More", "Show", "Hide", "Back", "Next", "Done", "Cancel", "Save", "Delete", "Share", "Copy", "Paste",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "January", "February",
        "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
        "Inactive", "Active", "Memory", "Platform", "Compose", "Sent", "Drafts", "Starred", "Snoozed", "Important",
        "Spam", "Trash", "Archive", "Labels", "Meet", "Chat", "Spaces", "Primary", "Promotions", "Social", "Updates",
        "Subject", "Recipients", "Formatting", "Attach", "Insert", "Schedule", "Discard", "Unread", "Mark", "Move",
        "Print", "Gmail", "Google", "Chrome", "Mail", "Notion", "Slack", "Untitled", "Loading", "Page", "Tab",
        "Menu", "Options", "Account", "Profile", "Notifications", "Filter", "Sort", "Add", "Remove", "Upload",
        "Body", "Message", "Press", "Bold", "Italic", "Underline", "Font", "Size", "Align", "Indent", "Undo", "Redo",
        "Minimise", "Minimize", "Maximise", "Maximize", "Close", "Pop", "Full", "Screen", "Saved", "Draft", "To", "Cc",
        "Bcc", "From", "Recipients", "Editor", "Toolbar", "Text", "Link", "Emoji", "Photo", "Signature", "Confidential"]

    /// Capitalised words that don't start a sentence, ranked by frequency.
    static func properNouns(in text: String, limit: Int = 10) -> [String] {
        var counts: [String: Int] = [:]
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        for (i, raw) in tokens.enumerated() {
            let w = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard w.count >= 3, w.count <= 25, let f = w.first, f.isUppercase, !stop.contains(w),
                  w.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { continue }
            if i > 0, let prev = tokens[i - 1].last, ".!?:".contains(prev) { continue }
            if w == w.uppercased() && w.count > 5 { continue }  // shouting labels, not names
            counts[w, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }
}
