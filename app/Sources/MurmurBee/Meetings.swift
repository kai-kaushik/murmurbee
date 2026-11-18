import AppKit
import SwiftUI

/// The Meetings page: your meetings on the left, the open one on the right.
struct MeetingsPane: View {
    @Bindable var meetings: MeetingController
    let flash: (String) -> Void

    private var selected: Meeting? { meetings.meetings.first { $0.id == meetings.selectedID } ?? meetings.meetings.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Meetings", subtitle: "Notes from your calls, written on this Mac.") {
                if meetings.phase == .recording {
                    Button("Stop") { meetings.stop() }.buttonStyle(HoneyButton())
                } else {
                    Button("Start notes") { meetings.startRecording() }.buttonStyle(HoneyButton())
                }
            }
            .padding(.horizontal, 36).padding(.top, 26).padding(.bottom, 18)

            if ModelStore.canRunAccurateNotes && !meetings.settings.notesModelAsked {
                modelChoice.padding(.horizontal, 36).padding(.bottom, 16)
            }

            if meetings.meetings.isEmpty {
                empty
            } else {
                HStack(alignment: .top, spacing: 0) {
                    list.frame(width: 230)
                    Rectangle().fill(Brand.border).frame(width: 1)
                    if let m = selected {
                        MeetingDetail(meeting: m, meetings: meetings, flash: flash).id(m.id)
                    }
                }
            }
        }
    }

    /// Only on Macs with the memory for the bigger model; everyone else gets the standard one without being asked.
    private var modelChoice: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Mac can run a bigger notes model").font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.linen)
                Text("Accurate makes fewer mistakes but writes shorter notes. 15 GB download.")
                    .font(.system(size: 12.5)).foregroundStyle(Brand.sand).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Keep Standard") { meetings.chooseNotesModel(accurate: false) }.buttonStyle(.plain).foregroundStyle(Brand.sand)
            Button("Use Accurate") { meetings.chooseNotesModel(accurate: true) }.buttonStyle(HoneyButton())
        }
        .font(.system(size: 13))
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No meetings yet").font(Brand.sora(18)).foregroundStyle(Brand.linen)
            Text("Join a call and MurmurBee will offer to take notes, or press Start notes. No bot joins, so tell people you’re recording.")
                .font(.system(size: 13)).foregroundStyle(Brand.sand).multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(meetings.meetings) { m in
                    Button { meetings.selectedID = m.id } label: { row(m) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 20)
        }
        .scrollIndicators(.never)
    }

    private func row(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(m.title.isEmpty ? "Meeting" : m.title).font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Brand.linen).lineLimit(1)
            Text(rowDetail(m)).font(.system(size: 12)).foregroundStyle(Brand.sand).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(m.id == selected?.id ? Brand.raised : .clear))
        .contentShape(Rectangle())
    }

    private func rowDetail(_ m: Meeting) -> String {
        switch m.status {
        case .recording: "Recording"
        case .processing: "Writing notes"
        case .failed: "Notes not finished"
        case .ready: m.date.formatted(.dateTime.day().month().hour().minute())
        }
    }
}

private struct MeetingDetail: View {
    enum Tab: String, CaseIterable { case notes = "Notes", transcript = "Transcript" }

    let meeting: Meeting
    @Bindable var meetings: MeetingController
    let flash: (String) -> Void
    @State private var tab = Tab.notes
    @State private var title = ""
    @State private var typed = ""
    @State private var confirming = false
    /// The speaker being renamed, and the name being typed.
    @State private var renaming: String?
    @State private var newName = ""

    private var recording: Bool { meeting.id == meetings.currentID }
    private var busy: Bool { meeting.status == .processing }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if recording {
                recordingView
            } else {
                if !meeting.transcript.isEmpty || !meeting.notes.isEmpty {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                content
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { title = meeting.title; typed = meeting.typed }
        .confirmationDialog("Delete this meeting?", isPresented: $confirming) {
            Button("Delete Meeting", role: .destructive) { meetings.delete(meeting.id) }
        } message: {
            Text("This removes its notes and transcript from this Mac.")
        }
        .alert("Rename \(renaming ?? "")", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let old = renaming { meetings.renameSpeaker(old, to: newName, id: meeting.id) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Changes the name in this meeting's transcript and notes.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                TextField("Meeting", text: $title)
                    .textFieldStyle(.plain).font(Brand.sora(18)).foregroundStyle(Brand.linen)
                    .onChange(of: title) { _, text in meetings.setTitle(text, id: meeting.id) }
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Brand.sand)
            }
            Spacer(minLength: 8)
            if !recording {
                // Only what fits the tab that's showing. Copy takes all of it, so a long transcript needn't be selected by hand.
                if tab == .transcript {
                    if !meeting.transcript.isEmpty { copyButton("Copy transcript", meeting.transcript, "Transcript copied") }
                } else {
                    if !meeting.notes.isEmpty { copyButton("Copy notes", meeting.fullNotes, "Notes copied") }
                    if !meeting.transcript.isEmpty, !busy {
                        Button("Rewrite notes") { meetings.retry(meeting.id) }.buttonStyle(.plain).foregroundStyle(Brand.sand)
                    }
                }
                if !busy {
                    Button { confirming = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(Brand.sand).help("Delete meeting")
                }
            }
        }
        .font(.system(size: 13))
    }

    private func copyButton(_ label: String, _ text: String, _ done: String) -> some View {
        Button(label) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            flash(done)
        }
        .buttonStyle(.plain).foregroundStyle(Brand.sand)
    }

    private var subtitle: String {
        var parts = [meeting.date.formatted(.dateTime.weekday(.wide).day().month().hour().minute())]
        let seconds = recording ? meetings.elapsed : meeting.durationS
        if seconds >= 60 { parts.append("\(Int(seconds / 60)) min") }
        return parts.joined(separator: ", ")
    }

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if meetings.callAudioMissing {
                HStack(spacing: 12) {
                    Text("MurmurBee can’t hear the call yet. If people are talking, allow it under System Audio Recording.")
                        .font(.system(size: 12.5)).foregroundStyle(Brand.linen)
                    Spacer(minLength: 8)
                    Button("Open Settings") { SystemPane.open(SystemPane.audioCapture) }.buttonStyle(HoneyButton())
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.surface))
            }
            Text("Type anything that matters. MurmurBee looks for it in the call, and keeps what you typed as you wrote it.")
                .font(.system(size: 13)).foregroundStyle(Brand.sand)
            TextEditor(text: $typed)
                .font(.system(size: 14)).scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.surface))
                .onChange(of: typed) { _, text in meetings.setTyped(text, id: meeting.id) }
        }
    }

    @ViewBuilder private var content: some View {
        if busy, tab == .notes || meeting.transcript.isEmpty {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(meetings.progress[meeting.id] ?? "Waiting for the last meeting to finish…")
                    .font(.system(size: 13.5)).foregroundStyle(Brand.sand)
            }
            .padding(.top, 8)
        } else if meeting.status == .failed, tab == .notes {
            VStack(alignment: .leading, spacing: 10) {
                Text(meeting.problem.isEmpty ? "The notes couldn’t be finished." : meeting.problem)
                    .font(.system(size: 13.5)).foregroundStyle(Brand.linen)
                Button("Try again") { meetings.retry(meeting.id) }.buttonStyle(HoneyButton())
            }
            .padding(.top, 8)
        } else {
            ScrollView {
                Group {
                    switch tab {
                    case .notes: NotesText(markdown: meeting.fullNotes)
                    case .transcript:
                        TranscriptText(text: meeting.transcript) { speaker in newName = speaker; renaming = speaker }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
    }
}

/// The small amount of Markdown the notes use: section headings, bullets, bold.
struct NotesText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    @ViewBuilder private func line(_ s: String) -> some View {
        if s.hasPrefix("#") {
            Text(s.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                .font(Brand.sora(14.5)).foregroundStyle(Brand.linen).padding(.top, 10)
        } else if s.hasPrefix("- ") || s.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Brand.honey).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                inline(String(s.dropFirst(2)))
            }
        } else if !s.isEmpty {
            inline(s)
        }
    }

    /// Bold and italic only. The notes model writes from what people said on the call, so a link in its output could
    /// point anywhere (another app's URL scheme, a file); links are shown as plain text and can't be clicked.
    private func inline(_ s: String) -> some View {
        var text = (try? AttributedString(markdown: s)) ?? AttributedString(s)
        for run in text.runs where run.link != nil { text[run.range].link = nil }
        return Text(text)
            .font(.system(size: 14)).foregroundStyle(Brand.linen).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Transcript lines, "[mm:ss] Speaker: text", with the time and speaker quieter than the words.
/// Click a speaker's name to rename them.
private struct TranscriptText: View {
    let text: String
    let rename: (String) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 9) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3 {
                    let speaker = parts[1].split(separator: "]").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Button(speaker) { rename(speaker) }
                                .buttonStyle(.plain).help("Rename \(speaker)")
                                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                            Text("\(parts[0].dropFirst()):\(parts[1].prefix(2))")
                        }
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Brand.sand)
                        Text(parts[2].trimmingCharacters(in: .whitespaces)).font(.system(size: 13.5)).foregroundStyle(Brand.linen)
                    }
                } else {
                    Text(line).font(.system(size: 13.5))
                }
            }
        }
    }
}

// MARK: - The floating bar

/// Stays above your other windows during a call: first to offer to take notes, then to show it's recording.
/// Drag it anywhere; it doesn't take focus from the call.
@MainActor
final class MeetingBar {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    weak var controller: MeetingController?
    private var panel: NSPanel?

    func update() {
        guard let controller else { return }
        if controller.phase == .idle { panel?.orderOut(nil); return }
        let panel = panel ?? make(controller)
        self.panel = panel
        let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 60)
        let top = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(top)
        panel.orderFrontRegardless()
    }

    private func make(_ controller: MeetingController) -> NSPanel {
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = NSHostingView(rootView: MeetingBarView(meetings: controller))
        if !p.setFrameUsingName("MeetingBar"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.maxX - 340, y: f.maxY - 14))
        }
        p.setFrameAutosaveName("MeetingBar")
        return p
    }
}

struct MeetingBarView: View {
    let meetings: MeetingController
    private let text = Color(red: 0xF7 / 255, green: 0xEF / 255, blue: 0xE0 / 255)
    private let quiet = Color(red: 0xC9 / 255, green: 0xBB / 255, blue: 0xA3 / 255)

    var body: some View {
        Group {
            if case .offering(let app) = meetings.phase { offer(app) } else { recording }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.barNight))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
        .gesture(WindowDragGesture())
        .environment(\.colorScheme, .dark)
    }

    private func offer(_ app: CallDetector.App) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name.isEmpty ? "Take notes on this call?" : "Take notes on this \(app.name) call?")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(text)
                Text("No bot joins, so tell people you’re recording.").font(.system(size: 12)).foregroundStyle(quiet)
            }
            HStack(spacing: 14) {
                Button("Take notes") { meetings.startRecording() }.buttonStyle(HoneyButton())
                Button("Not now") { meetings.dismissOffer() }.buttonStyle(.plain).foregroundStyle(quiet)
                Button("Don’t ask again") { meetings.neverOffer() }.buttonStyle(.plain).foregroundStyle(quiet)
            }
            .font(.system(size: 12.5))
        }
        .padding(14)
        .frame(width: 310, alignment: .leading)
    }

    private var recording: some View {
        HStack(spacing: 10) {
            Circle().fill(Brand.honeyFill).frame(width: 8, height: 8)
            Button { meetings.openMeetings() } label: {
                Text(clock).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(text)
            }
            .buttonStyle(.plain).help("Open your notes")
            Button("Stop") { meetings.stop() }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.honeyFill)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .fixedSize()
    }

    private var clock: String {
        let t = Int(meetings.elapsed)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}
