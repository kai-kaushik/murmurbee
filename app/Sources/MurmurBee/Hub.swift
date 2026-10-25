import AppKit
import SwiftUI

/// The main window: your dictation history (search, copy), dictionary and settings. Opens from the Dock.
@MainActor
@Observable
final class HubModel {
    enum Pane: String, CaseIterable, Identifiable {
        case history = "History", dictionary = "Dictionary", settings = "Settings", privacy = "Privacy"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .history: "clock.arrow.circlepath"
            case .dictionary: "character.book.closed"
            case .settings: "gearshape"
            case .privacy: "lock"
            }
        }
    }
    var pane: Pane = .history
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
            Rectangle().fill(Brand.border).frame(width: 1)
            Group {
                switch model.pane {
                case .history: HistoryPane(store: store)
                case .dictionary: DictionaryTab()
                case .settings: GeneralTab(settings: settings, permissions: permissions)
                case .privacy: PrivacyTab(settings: settings, deleteHistory: deleteHistory)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.night)
        }
        .frame(minWidth: 780, minHeight: 520)
        .brandWindow()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let bee = Brand.bee { Image(nsImage: bee).resizable().interpolation(.high).frame(width: 28, height: 28) }
                Wordmark(size: 18)
            }
            .padding(.horizontal, 10).padding(.top, 34).padding(.bottom, 18)  // clears the traffic lights
            ForEach(HubModel.Pane.allCases) { p in
                Button { model.pane = p } label: {
                    Label(p.rawValue, systemImage: p.icon)
                        .font(.system(size: 13, weight: model.pane == p ? .semibold : .regular))
                        .foregroundStyle(model.pane == p ? Brand.linen : Brand.sand)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(model.pane == p ? Brand.raised : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Hold \(settings.holdKey.rawValue) to talk")
                .font(.caption).foregroundStyle(Brand.sand)
                .padding(10)
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
        .frame(width: 210)
        .background(Brand.surface)
    }
}

// MARK: - History

private struct HistoryPane: View {
    let store: Store
    @State private var items: [HistoryItem] = []
    @State private var search = ""
    @State private var copied: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("History").font(Brand.sora(26))
                Spacer()
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Brand.raised))
                    .overlay(Capsule().stroke(Brand.border))
                    .frame(width: 240)
            }
            .padding(.horizontal, 28).padding(.top, 40)

            if !items.isEmpty && search.isEmpty { stats.padding(.horizontal, 28).padding(.top, 16) }

            if items.isEmpty {
                VStack(spacing: 10) {
                    if let bee = Brand.bee { Image(nsImage: bee).resizable().frame(width: 64, height: 64).opacity(0.9) }
                    Text(search.isEmpty ? "Nothing here yet" : "No matches").font(.headline)
                    Text(search.isEmpty ? "Your dictations will appear here, ready to copy." : "Try another word.")
                        .foregroundStyle(Brand.sand)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(days, id: \.0) { day, rows in
                            Section {
                                ForEach(rows) { row($0) }
                            } header: {
                                Text(day).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.sand)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 28).padding(.vertical, 8)
                                    .background(Brand.night)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .padding(.top, 12)
            }
        }
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            await reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyChanged)) { _ in Task { await reload() } }
    }

    private func reload() async { items = await store.history(search: search) }

    private var stats: some View {
        let words = items.reduce(0) { $0 + $1.words }
        let minutes = items.reduce(0) { $0 + $1.durationS } / 60
        let wpm = minutes > 0 ? Double(words) / minutes : 0
        return HStack(spacing: 28) {
            stat("\(items.count)", "dictations")
            stat(words.formatted(), "words")
            if wpm > 0 { stat(String(format: "%.0f", wpm), "words per minute") }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(Brand.sora(20)).foregroundStyle(Brand.honey)
            Text(label).font(.callout).foregroundStyle(Brand.sand)
        }
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

    private func row(_ item: HistoryItem) -> some View {
        HistoryRow(item: item, copied: copied == item.id,
                   copy: {
                       NSPasteboard.general.clearContents()
                       NSPasteboard.general.setString(item.text, forType: .string)
                       copied = item.id
                       Task { try? await Task.sleep(for: .seconds(1.5)); if copied == item.id { copied = nil } }
                   },
                   delete: { Task { await store.delete(item.id); await reload() } })
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let copied: Bool
    let copy: () -> Void
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.date, format: .dateTime.hour().minute()).font(.system(size: 12, weight: .medium))
                if !item.app.isEmpty {
                    Text(item.app).font(.system(size: 11)).foregroundStyle(Brand.sand).lineLimit(1)
                }
            }
            .frame(width: 84, alignment: .leading)
            Text(item.text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copied ? Brand.night : Brand.linen)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(copied ? Brand.honey : Brand.raised))
            }
            .buttonStyle(.plain)
            .opacity(hover || copied ? 1 : 0)
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
        .background(hover ? Brand.surface : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Copy", action: copy)
            Button("Delete", role: .destructive, action: delete)
        }
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
