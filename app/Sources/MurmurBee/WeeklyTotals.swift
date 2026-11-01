import Foundation

/// "Share anonymous word counts": opt-in, off by default, asked once on Home after a week of use. Once a week it sends
/// rounded totals for the past seven days: words and dictations as ranges, days used, the share of dictations you
/// edited (to the nearest 10%), and the app and macOS versions. Never any text, app names, or a lasting id: the id
/// is random and replaced every month, so weeks can be counted but not linked to a person.
@MainActor
enum WeeklyTotals {
    static var store: Store?
    private static let d = UserDefaults.standard
    private static let week: TimeInterval = 7 * 24 * 3600

    /// Called at launch: checks now and every few hours whether a report is due.
    static func start(store: Store) {
        self.store = store
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { sendIfDue() }
        }
        sendIfDue()
    }

    /// Turning sharing on starts the clock: the first report goes a week later. Turning it off forgets the clock.
    static func settingChanged(_ on: Bool) {
        if on { d.set(Date(), forKey: "totalsLastSent") } else { d.removeObject(forKey: "totalsLastSent") }
    }

    /// Home asks once the first MurmurBee dictation is at least a week old.
    static func shouldAsk(_ settings: Settings) async -> Bool {
        guard !settings.shareTotalsAsked, !settings.shareTotals, let store else { return false }
        guard let first = await store.usage(since: .distantFuture).first else { return false }
        return Date().timeIntervalSince(first) >= week
    }

    static func sendIfDue() {
        guard Settings.shared.shareTotals, let store else { return }
        guard let last = d.object(forKey: "totalsLastSent") as? Date else { settingChanged(true); return }
        guard Date().timeIntervalSince(last) >= week else { return }
        Task {
            let u = await store.usage(since: Date().addingTimeInterval(-week))
            if (try? await send(u)) != nil { d.set(Date(), forKey: "totalsLastSent") }
        }
    }

    static func properties(_ u: Store.Usage) -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "words": range(u.words, [100, 500, 1000, 2500, 5000, 10000, 25000]),
            "dictations": range(u.dictations, [10, 50, 100, 250, 500, 1000]),
            "days_used": u.days,
            "edited_share": u.dictations == 0 ? 0 : Int((Double(u.edited) / Double(u.dictations) * 10).rounded()) * 10,
            "app_version": Updates.version,
            "macos": "\(os.majorVersion).\(os.minorVersion)",
            "$process_person_profile": false,
        ]
    }

    /// "0", "1-100", "100-500", … "25000+".
    static func range(_ n: Int, _ edges: [Int]) -> String {
        if n == 0 { return "0" }
        var low = 1
        for e in edges {
            if n < e { return "\(low)-\(e)" }
            low = e
        }
        return "\(low)+"
    }

    /// A random id that changes when the month does.
    private static var monthId: String {
        let month = Date().formatted(.iso8601.year().month())
        if d.string(forKey: "totalsIdMonth") != month {
            d.set(month, forKey: "totalsIdMonth")
            d.set(UUID().uuidString, forKey: "totalsId")
        }
        return d.string(forKey: "totalsId") ?? UUID().uuidString
    }

    private static func send(_ u: Store.Usage) async throws {
        let body: [String: Any] = ["api_key": Feedback.projectKey, "event": "weekly_totals",
                                   "distinct_id": monthId, "properties": properties(u)]
        var request = URLRequest(url: Feedback.endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
