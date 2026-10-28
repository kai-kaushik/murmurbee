import AppKit
import SwiftUI

/// The main window (opens from the Dock): history first, then the dictionary. Settings is a sheet.
@MainActor
@Observable
final class HubModel {
    enum Pane: String, CaseIterable, Identifiable {
        case history = "Home", dictionary = "Dictionary", model = "Your model", settings = "Settings", privacy = "Privacy"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .history: "house"
            case .dictionary: "character.book.closed"
            case .model: "sparkles"
            case .settings: "gearshape"
            case .privacy: "lock"
            }
        }
    }
    /// The page in the window: Home or Dictionary.
    var pane: Pane = .history
    /// Settings opens as a sheet over the window, on General or Privacy.
    var settingsPane: Pane?
    var toast: String?
    var feedbackOpen = false

    func show(_ p: Pane) {
        switch p {
        case .history, .dictionary, .model: pane = p; settingsPane = nil
        case .settings, .privacy: settingsPane = p
        }
    }

    func flash(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if toast == text { toast = nil }
        }
    }
}

struct HubView: View {
    @Bindable var model: HubModel
    let store: Store
    let settings: Settings
    let permissions: Permissions
    let deleteHistory: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Group {
                switch model.pane {
                case .dictionary: DictionaryPane(model: model)
                case .model: YourModelPane(hub: model)
                default: HomePane(model: model, store: store, settings: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.night)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 14,
                                              bottomTrailingRadius: 14, topTrailingRadius: 20))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 14,
                                            bottomTrailingRadius: 14, topTrailingRadius: 20).stroke(Brand.border))
            .padding(.top, 10).padding(.trailing, 10).padding(.bottom, 10)
        }
        .background(Brand.surface)
        .ignoresSafeArea()  // run under the transparent title bar; the sidebar clears the traffic lights itself
        .overlay(alignment: .bottomTrailing) {
            if let toast = model.toast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.honey)
                    Text(toast).font(.system(size: 13))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.raised))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.border))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .padding(24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.toast)
        .sheet(item: $model.settingsPane) { pane in
            SettingsSheet(initial: pane, settings: settings, permissions: permissions,
                          deleteHistory: deleteHistory, close: { model.settingsPane = nil })
        }
        .sheet(isPresented: $model.feedbackOpen) {
            FeedbackSheet { sent in
                model.feedbackOpen = false
                if sent { model.flash("Thanks! Your feedback was sent.") }
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .brandWindow()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let bee = Brand.bee { Image(nsImage: bee).resizable().interpolation(.high).frame(width: 26, height: 26) }
                Wordmark(size: 17)
            }
            .padding(.horizontal, 8).padding(.top, 44).padding(.bottom, 16)  // below the traffic lights
            navItem(.history)
            navItem(.dictionary)
            navItem(.model)
            Spacer()
            Rectangle().fill(Brand.border).frame(height: 1).padding(.vertical, 8)
            ThemeToggle()
            navButton("Settings", "gearshape") { model.show(.settings) }
            navButton("Send feedback", "bubble.left") { model.feedbackOpen = true }
            navButton("Help", "questionmark.circle") {
                NSWorkspace.shared.open(URL(string: "https://github.com/kai-kaushik/murmurbee#readme")!)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 14)
        .frame(width: 216)
    }

    private func navItem(_ p: HubModel.Pane) -> some View {
        navButton(p.rawValue, p.icon, active: model.pane == p) { model.show(p) }
    }

    private func navButton(_ title: String, _ icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 20)
                Text(title)
            }
            .font(.system(size: 14, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? Brand.linen : Brand.sand)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Brand.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Sun / moon switch at the bottom of the sidebar; wipes the window into the other theme.
private struct ThemeToggle: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button { Theme.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: scheme == .dark ? "sun.max" : "moon").frame(width: 20)
                Text(scheme == .dark ? "Light mode" : "Dark mode")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Brand.sand)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch to \(scheme == .dark ? "light" : "dark") mode")
    }
}

// MARK: - Page shell

private struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Brand.sora(24)).foregroundStyle(Brand.linen)
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Brand.sand) }
            }
            Spacer()
            trailing
        }
    }
}

private struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Brand.sand)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Brand.border))
        .frame(width: 240)
    }
}

/// A key cap like the ones on the website.
private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Brand.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.border))
    }
}

// MARK: - Home (history)

private struct HomePane: View {
    let model: HubModel
    private let importer = WisprImporter.shared
    let store: Store
    let settings: Settings
    @State private var items: [HistoryItem] = []
    @State private var all: [HistoryItem] = []
    @State private var search = ""

    private var firstName: String {
        let n = settings.signName.isEmpty ? NSFullUserName() : settings.signName
        return n.split(separator: " ").first.map(String.init) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: all.isEmpty ? "Hi \(firstName), let’s get talking" : "Welcome back, \(firstName)") {
                SearchField(prompt: "Search past dictations", text: $search)
            }
            .padding(.horizontal, 36).padding(.top, 26).padding(.bottom, 18)

            if importer.offerOnHome {
                WisprCard(importer: importer, flash: model.flash).padding(.horizontal, 36).padding(.bottom, 16)
            }

            if all.isEmpty {
                empty
            } else {
                GeometryReader { geo in
                    ScrollView {
                        if geo.size.width >= 900 {
                            HStack(alignment: .top, spacing: 24) {
                                list.frame(maxWidth: .infinity)
                                if search.isEmpty { stats(vertical: true).frame(width: 230) }
                            }
                            .padding(.horizontal, 36).padding(.bottom, 32)
                        } else {
                            VStack(alignment: .leading, spacing: 16) {
                                if search.isEmpty { stats(vertical: false) }
                                list
                            }
                            .padding(.horizontal, 36).padding(.bottom, 32)
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            await reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyChanged)) { _ in Task { await reload() } }
    }

    private func reload() async {
        items = await store.history(search: search)
        if search.isEmpty { all = items } else if all.isEmpty { all = await store.history() }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            if let bee = Brand.bee { Image(nsImage: bee).resizable().frame(width: 72, height: 72) }
            Text("No dictations yet").font(Brand.sora(20))
            HStack(spacing: 6) {
                Text("Hold").foregroundStyle(Brand.sand)
                KeyCap(text: settings.holdKey.short)
                Text("in any app, say something, and let go.").foregroundStyle(Brand.sand)
            }
            .font(.system(size: 14))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var list: some View {
        if items.isEmpty {
            Text("No dictations match “\(search)”.").foregroundStyle(Brand.sand).padding(.top, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(days, id: \.0) { day, rows in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(day.uppercased())
                            .font(.system(size: 11, weight: .semibold)).tracking(0.9)
                            .foregroundStyle(Brand.sand)
                            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Rectangle().fill(Brand.border).frame(height: 1).padding(.leading, 18) }
                            HistoryRow(item: item,
                                       copy: { copy(item) },
                                       delete: { Task { await store.delete(item.id); await reload(); model.flash("Dictation deleted") } })
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.border))
                }
            }
        }
    }

    private func copy(_ item: HistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        model.flash("Copied. Paste anywhere with ⌘V")
    }

    private var days: [(String, [HistoryItem])] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE d MMMM"
        var out: [(String, [HistoryItem])] = []
        for item in items {
            let label = cal.isDateInToday(item.date) ? "Today" : cal.isDateInYesterday(item.date) ? "Yesterday" : fmt.string(from: item.date)
            if out.last?.0 == label { out[out.count - 1].1.append(item) } else { out.append((label, [item])) }
        }
        return out
    }

    private func stats(vertical: Bool) -> some View {
        let words = all.reduce(0) { $0 + $1.words }
        let minutes = all.reduce(0) { $0 + $1.durationS } / 60
        let wpm = minutes > 0 ? Int((Double(words) / minutes).rounded()) : 0
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                              : AnyLayout(HStackLayout(alignment: .center, spacing: 32))
        return layout {
            stat(words.formatted(), "total words")
            if wpm > 0 { stat("\(wpm)", "words per minute") }
            stat("\(streak)", "day streak")
            if vertical {
                Rectangle().fill(Brand.border).frame(height: 1)
                HStack(spacing: 6) {
                    Text("Hold").foregroundStyle(Brand.sand)
                    KeyCap(text: settings.holdKey.short)
                    Text("to talk").foregroundStyle(Brand.sand)
                }
                .font(.system(size: 13)).fixedSize()
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(vertical ? 20 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.border))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(Brand.sora(28)).foregroundStyle(Brand.honey)
            Text(label).font(.system(size: 13)).foregroundStyle(Brand.sand).lineLimit(1)
        }
        .fixedSize()
    }

    /// Consecutive days with a dictation, ending today (or yesterday, so the streak survives until tonight).
    private var streak: Int {
        let cal = Calendar.current
        let days = Set(all.map { cal.startOfDay(for: $0.date) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(day) { n += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
        return n
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let copy: () -> Void
    let delete: () -> Void
    @State private var hover = false
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.date, format: .dateTime.hour().minute()).font(.system(size: 12)).foregroundStyle(Brand.sand)
                if !item.app.isEmpty {
                    Text(item.app).font(.system(size: 11)).foregroundStyle(Brand.sand.opacity(0.7)).lineLimit(1)
                }
            }
            .frame(width: 76, alignment: .leading)
            Text(item.text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(Brand.linen)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                iconButton("doc.on.doc", "Copy", copy)
                iconButton("trash", "Delete") { confirming = true }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 9).fill(Brand.surface).shadow(color: .black.opacity(0.3), radius: 6))
            .padding(.top, 6).padding(.trailing, 10)
            .opacity(hover ? 1 : 0)
        }
        .background(hover ? Brand.raised.opacity(0.55) : .clear)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture(perform: copy)
        .contextMenu {
            Button("Copy", action: copy)
            Button("Delete", role: .destructive) { confirming = true }
        }
        .confirmationDialog("Delete this dictation?", isPresented: $confirming) {
            Button("Delete", role: .destructive, action: delete)
        } message: { Text("It can’t be recovered.") }
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Brand.linen)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Brand.raised))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// "Bring your Wispr Flow history": shown on Home when Wispr Flow's data is on this Mac.
private struct WisprCard: View {
    let importer: WisprImporter
    let flash: (String) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "arrow.down.doc").font(.system(size: 22)).foregroundStyle(Brand.honey).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text("Bring your Wispr Flow history").font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.linen)
                Group {
                    if let p = importer.progress {
                        Text("Importing… \(p.done.formatted()) of \(p.total.formatted()) dictations")
                    } else if let f = importer.found {
                        Text("Found \(f.dictations.formatted()) dictations and \(f.words) dictionary words on this Mac. Import them so MurmurBee knows your words from day one. Nothing leaves your Mac.")
                    }
                }
                .font(.system(size: 13)).foregroundStyle(Brand.sand).fixedSize(horizontal: false, vertical: true)
                if let p = importer.progress, p.total > 0 {
                    ProgressView(value: Double(p.done), total: Double(p.total)).tint(Brand.honeyFill).padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            if !importer.running {
                Button("Not now") { importer.dismissed = true }.buttonStyle(.plain).foregroundStyle(Brand.sand)
                Button("Import") {
                    importer.start { r in flash("Imported \(r.dictations.formatted()) dictations and \(r.words) words") }
                }.buttonStyle(HoneyButton())
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.honey.opacity(0.35)))
    }
}

// MARK: - Your model (personal training)

private struct YourModelPane: View {
    let hub: HubModel
    private let trainer = PersonalTrainer.shared
    private let importer = WisprImporter.shared
    @State private var personal = PersonalInfo.load()
    private var activeName: String { ModelStore.best()?.lastPathComponent ?? PersonalTrainer.generalName }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Your model",
                           subtitle: "MurmurBee learns your words and style from your own dictations, on this Mac.") { EmptyView() }
                current
                trainCard
                if importer.offerOnHome {
                    WisprCard(importer: importer, flash: hub.flash)
                }
                Text("How it works: your newest dictations are held back as a test. A personal model is trained on the rest, then both models clean the held-back dictations, and the new one is only switched in if it makes fewer mistakes. Nothing leaves your Mac.")
                    .font(.system(size: 12.5)).foregroundStyle(Brand.sand).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 36).padding(.top, 26).padding(.bottom, 32)
        }
        .scrollIndicators(.never)
        .onAppear { trainer.refresh(); personal = PersonalInfo.load() }
        .onChange(of: trainer.phase) { personal = PersonalInfo.load() }
    }

    private var current: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: personal == nil ? "cube" : "sparkles").font(.system(size: 20)).foregroundStyle(Brand.honey)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(personal != nil ? "Using your personal model"
                     : activeName == PersonalTrainer.generalName ? "Using the general model" : "Using \(activeName)")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.linen)
                Text(personal.map { p in
                    "Trained \(p.trained.formatted(date: .abbreviated, time: .omitted)) on \(p.examples.formatted()) of your dictations. " +
                    "On your held-back dictations it made \(p.improvement)% fewer mistakes than the model before it."
                } ?? (activeName == PersonalTrainer.generalName
                      ? "Trained for everyone, on made-up examples. A personal model learns your names, phrasing and style."
                      : "A custom model installed on this Mac. Training a personal model compares against it and only switches if it's better."))
                    .font(.system(size: 13)).foregroundStyle(Brand.sand).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if personal != nil {
                Button("Use the general model") {
                    try? FileManager.default.removeItem(at: PersonalTrainer.personalDir)
                    personal = nil
                    NotificationCenter.default.post(name: .personalModelInstalled, object: nil)
                    hub.flash("Switched back to the general model")
                }.buttonStyle(.plain).foregroundStyle(Brand.sand)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.border))
    }

    private var trainCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(trainer.available.formatted())").font(Brand.sora(28)).foregroundStyle(Brand.honey)
                Text("dictations to learn from").font(.system(size: 13)).foregroundStyle(Brand.sand)
                Spacer()
                if trainer.running {
                    Button("Stop") { trainer.stop() }.buttonStyle(.plain).foregroundStyle(Brand.sand)
                } else {
                    Button(personal == nil ? "Train my model" : "Train again") { trainer.start() }
                        .buttonStyle(HoneyButton()).disabled(trainer.available < 200)
                }
            }
            status
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.border))
    }

    @ViewBuilder private var status: some View {
        switch trainer.phase {
        case .idle:
            Text(trainer.available < 200
                 ? "Needs at least 200 dictations. Keep dictating, or import your Wispr Flow history."
                 : "Takes up to about 2 hours with a big history, so overnight is ideal. MurmurBee keeps working while it trains, and training pauses whenever you dictate.")
                .font(.system(size: 13)).foregroundStyle(Brand.sand)
        case .preparing:
            line("Getting your dictations ready…", nil)
        case .checkingCurrent(let d, let t):
            line("Testing the model you use now on your held-back dictations (\(d) of \(t))", Double(d) / Double(max(1, t)) * 0.1)
        case .training(let st, let n, _):
            line("Training on your dictations: step \(st) of \(n)", 0.1 + Double(st) / Double(max(1, n)) * 0.8)
        case .checkingNew(let d, let t):
            line("Testing your new model (\(d) of \(t))", 0.9 + Double(d) / Double(max(1, t)) * 0.1)
        case .finished(let o):
            Text(o.installed
                 ? "Your new model is live. On \(o.heldOut) held-back dictations it made \(pct(o))% fewer mistakes (word error rate \(f(o.currentWER)) → \(f(o.newWER)))."
                 : "Your new model wasn't better than the one you use now on \(o.heldOut) held-back dictations (\(f(o.newWER)) vs \(f(o.currentWER))), so nothing changed. More history usually helps.")
                .font(.system(size: 13)).foregroundStyle(o.installed ? Brand.linen : Brand.sand)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let msg):
            Text("Training stopped: \(msg)").font(.system(size: 13)).foregroundStyle(Brand.sand)
        }
    }

    private func line(_ text: String, _ progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 13)).foregroundStyle(Brand.linen)
            if let progress { ProgressView(value: progress).tint(Brand.honeyFill) } else { ProgressView().controlSize(.small) }
        }
    }
    private func f(_ x: Double) -> String { String(format: "%.3f", x) }
    private func pct(_ o: PersonalTrainer.Outcome) -> Int {
        o.currentWER > 0 ? Int(((o.currentWER - o.newWER) / o.currentWER * 100).rounded()) : 0
    }
}

/// What the installed personal model's localflow.json says about it.
private struct PersonalInfo: Equatable {
    let trained: Date, examples: Int, improvement: Int
    static func load() -> PersonalInfo? {
        let url = PersonalTrainer.personalDir.appendingPathComponent("localflow.json")
        guard let data = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let wer = j["wer"] as? Double ?? 0, cur = j["currentWer"] as? Double ?? 0
        return PersonalInfo(trained: (j["trained"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(),
                            examples: j["examples"] as? Int ?? 0,
                            improvement: cur > 0 ? Int(((cur - wer) / cur * 100).rounded()) : 0)
    }
}

// MARK: - Dictionary

private struct DictionaryPane: View {
    let model: HubModel
    struct Term: Identifiable, Hashable { var id: String { text }; var text: String; var auto: Bool }
    @State private var terms: [Term] = []
    @State private var search = ""
    @State private var adding = false
    @State private var newTerm = ""

    private var shown: [Term] {
        search.isEmpty ? terms : terms.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Dictionary", subtitle: "Names and words MurmurBee should always spell right.") {
                SearchField(prompt: "Search your words", text: $search)
                Button("Add word") { adding = true }.buttonStyle(HoneyButton())
            }
            .padding(.horizontal, 36).padding(.top, 26).padding(.bottom, 18)

            if adding {
                HStack(spacing: 8) {
                    TextField("A name or word, spelled the way you want it", text: $newTerm)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Brand.surface))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Brand.honey.opacity(0.6)))
                        .onSubmit(add)
                    Button("Add", action: add).buttonStyle(HoneyButton())
                    Button("Cancel") { adding = false; newTerm = "" }.buttonStyle(.plain).foregroundStyle(Brand.sand)
                }
                .padding(.horizontal, 36).padding(.bottom, 14)
            }

            if terms.isEmpty {
                Text("No words yet. Add names you use often, or correct a pasted word and MurmurBee will learn it.")
                    .foregroundStyle(Brand.sand).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                            if i > 0 { Rectangle().fill(Brand.border).frame(height: 1).padding(.leading, 18) }
                            TermRow(term: t) { remove(t) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.border))
                    .padding(.horizontal, 36).padding(.bottom, 32)
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        _ = Vocabulary.dictionary()
        let text = (try? String(contentsOf: Vocabulary.file, encoding: .utf8)) ?? ""
        var seen = Set<String>()
        terms = text.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: " #")
            let t = parts[0].trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), seen.insert(t).inserted else { return nil }
            return Term(text: t, auto: parts.count > 1 && parts[1].contains("auto"))
        }
    }

    private func add() {
        let t = newTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if !terms.contains(where: { $0.text == t }) { terms.insert(Term(text: t, auto: false), at: 0); save() }
        newTerm = ""
        adding = false
        model.flash("“\(t)” added")
    }

    private func remove(_ t: Term) {
        terms.removeAll { $0.text == t.text }
        save()
        model.flash("“\(t.text)” removed")
    }

    private func save() {
        let text = terms.map { $0.auto ? "\($0.text)  # auto" : $0.text }.joined(separator: "\n") + "\n"
        try? text.write(to: Vocabulary.file, atomically: true, encoding: .utf8)
    }
}

private struct TermRow: View {
    let term: DictionaryPane.Term
    let remove: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            Text(term.text).font(.system(size: 14)).foregroundStyle(Brand.linen)
            if term.auto { Text("✨").help("Learned from your edits") }
            Spacer()
            Button(action: remove) {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Brand.linen)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Brand.raised))
            }
            .buttonStyle(.plain).help("Remove").opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(hover ? Brand.raised.opacity(0.55) : .clear)
        .onHover { hover = $0 }
    }
}

// MARK: - Settings sheet

private struct SettingsSheet: View {
    let initial: HubModel.Pane
    let settings: Settings
    let permissions: Permissions
    let deleteHistory: () -> Void
    let close: () -> Void
    @State private var pane: HubModel.Pane = .settings

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SETTINGS").font(.system(size: 11, weight: .semibold)).tracking(0.9).foregroundStyle(Brand.sand)
                    .padding(.horizontal, 8).padding(.bottom, 6)
                rail("General", "gearshape", .settings)
                rail("Privacy", "lock", .privacy)
                Spacer()
                Text("MurmurBee \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.system(size: 11)).foregroundStyle(Brand.sand).padding(.horizontal, 8)
                HStack(spacing: 10) {
                    Button("Licences") {
                        if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Terms") { NSWorkspace.shared.open(URL(string: "https://murmurbee.com/terms/")!) }
                    Button("Privacy") { NSWorkspace.shared.open(URL(string: "https://murmurbee.com/privacy/")!) }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Brand.sand)
                .lineLimit(1).fixedSize()  // keep "Licences" on one line in the narrow sidebar
                .padding(.horizontal, 8).padding(.top, 2)
            }
            .padding(14).padding(.top, 8)
            .frame(width: 180)
            .background(Brand.surface)
            Rectangle().fill(Brand.border).frame(width: 1)
            VStack(spacing: 0) {
                HStack {
                    Text(pane == .privacy ? "Privacy" : "General").font(Brand.sora(20))
                    Spacer()
                    Button("Done", action: close).buttonStyle(HoneyButton()).keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 24).padding(.top, 20)
                if pane == .privacy {
                    PrivacyTab(settings: settings, deleteHistory: deleteHistory)
                } else {
                    GeneralTab(settings: settings, permissions: permissions)
                }
            }
            .background(Brand.night)
        }
        .frame(width: 780, height: 620)
        .onAppear { pane = initial }
        .brandWindow()
    }

    private func rail(_ title: String, _ icon: String, _ p: HubModel.Pane) -> some View {
        Button { pane = p } label: {
            HStack(spacing: 8) { Image(systemName: icon).frame(width: 18); Text(title) }
                .font(.system(size: 13, weight: pane == p ? .semibold : .medium))
                .foregroundStyle(pane == p ? Brand.linen : Brand.sand)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(pane == p ? Brand.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Confetti

/// A short burst of honey, linen and blush confetti. Respects Reduce Motion.
struct Confetti: View {
    let trigger: Int
    @State private var start: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Bit { let x, vx, vy, spin, size: Double; let color: Color }
    @State private var bits: [Bit] = []
    private let duration = 2.6

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { tl in
            Canvas { ctx, size in
                guard let start else { return }
                let t = tl.date.timeIntervalSince(start)
                guard t < duration else { return }
                for b in bits {
                    let x = b.x * size.width + b.vx * t * 60
                    let y = -20 + b.vy * t * 60 + 0.5 * 420 * t * t
                    var c = ctx
                    c.opacity = max(0, 1 - t / duration)
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(b.spin * t))
                    c.fill(Path(roundedRect: CGRect(x: -b.size / 2, y: -b.size / 4, width: b.size, height: b.size / 2),
                                cornerRadius: 1.5), with: .color(b.color))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { fire() }
        .onAppear { if trigger > 0 { fire() } }
    }

    private func fire() {
        guard !reduceMotion else { return }
        let colors = [Brand.honey, Brand.honey, Brand.linen, Color(red: 0.95, green: 0.63, blue: 0.48)]
        bits = (0..<110).map { _ in
            Bit(x: .random(in: 0...1), vx: .random(in: -1.2...1.2), vy: .random(in: 0.5...3.2),
                spin: .random(in: -9...9), size: .random(in: 6...11), color: colors.randomElement()!)
        }
        start = Date()
        Task { try? await Task.sleep(for: .seconds(duration + 0.2)); start = nil }
    }
}
