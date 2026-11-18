import AppKit
import Foundation
import Observation
import os

/// Meeting notes from start to finish: noticing a call, recording it, then turning it into notes in the background.
@MainActor
@Observable
final class MeetingController {
    static let shared = MeetingController()

    enum Phase: Equatable {
        case idle
        case offering(CallDetector.App)
        case recording
    }

    private(set) var phase = Phase.idle
    private(set) var meetings: [Meeting] = []
    /// The meeting being recorded.
    private(set) var currentID: Int64?
    private(set) var elapsed = 0.0
    /// What's happening to the meeting being processed, by id.
    private(set) var progress: [Int64: String] = [:]
    /// True while a call is going and the call audio has stayed silent, which is what a missing permission looks like.
    private(set) var callAudioMissing = false
    /// The meeting open on the Meetings page.
    var selectedID: Int64?

    @ObservationIgnored var store: Store?
    @ObservationIgnored var settings = Settings.shared
    @ObservationIgnored var microphone: () -> String = { "auto" }
    @ObservationIgnored var openMeetings: () -> Void = {}
    @ObservationIgnored var flash: (String) -> Void = { _ in }
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored private let recorder = MeetingRecorder()
    @ObservationIgnored private let bar = MeetingBar()
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var queue: [Int64] = []
    @ObservationIgnored private var working = false
    @ObservationIgnored private var saveTyped: Task<Void, Never>?
    @ObservationIgnored private var starting = false

    // What the once-a-second check remembers about the call.
    @ObservationIgnored private var seen: (app: CallDetector.App, since: Date)?
    @ObservationIgnored private var offeredAt = Date()
    @ObservationIgnored private var declined: String?
    @ObservationIgnored private var callApp = false
    @ObservationIgnored private var lastCallApp = Date()

    private static let noticeCallAfter = 8.0
    /// What the recording decided and why, without anything that was said: `log show --predicate 'subsystem ==
    /// "com.murmurbee.app"' --last 2h`.
    private static let log = Logger(subsystem: "com.murmurbee.app", category: "meetings")

    static var audioRoot: URL { Store.directory.appendingPathComponent("meeting-audio") }
    private static func audioDir(_ id: Int64) -> URL { audioRoot.appendingPathComponent("\(id)") }

    var current: Meeting? { meetings.first { $0.id == currentID } }

    func start(store: Store) {
        self.store = store
        bar.controller = self
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Task {
            await reload()
            // Anything left unfinished by a quit or a crash picks up where it stopped.
            for m in meetings where m.status == .recording || m.status == .processing {
                var m = m
                m.status = .processing
                await save(m)
                queue.append(m.id)
            }
            drain()
        }
    }

    private func reload() async {
        guard let store else { return }
        meetings = await store.meetings()
    }

    private func save(_ m: Meeting) async {
        await store?.saveMeeting(m)
        if let i = meetings.firstIndex(where: { $0.id == m.id }) { meetings[i] = m }
    }

    private func updated(_ id: Int64, _ change: (inout Meeting) -> Void) async {
        guard var m = meetings.first(where: { $0.id == id }) else { return }
        change(&m)
        await save(m)
    }

    // MARK: Noticing a call

    private func tick() {
        switch phase {
        case .recording:
            let now = Date()
            elapsed = now.timeIntervalSince(started)
            recorder.followOutput()
            let apps = CallDetector.appsUsingMicrophone()
            if !apps.isEmpty {
                if !callApp { Self.log.info("call app using the mic: \(apps.map(\.bundle).joined(separator: ", "), privacy: .public)") }
                callApp = true
                lastCallApp = now
            }
            callAudioMissing = callApp && recorder.callHeard == nil && elapsed > 30
            let state = AutoStop.State(elapsed: elapsed, sawCallApp: callApp, sinceCallApp: now.timeIntervalSince(lastCallApp),
                                       sinceCallSound: now.timeIntervalSince(recorder.callHeard ?? started),
                                       sinceMicSound: now.timeIntervalSince(recorder.micHeard ?? started))
            if Int(elapsed) % 30 == 0 { Self.log.info("recording: \(state.description, privacy: .public)") }
            if let reason = AutoStop.reason(state) {
                Self.log.info("stopping by itself: \(reason, privacy: .public) (\(state.description, privacy: .public))")
                stop()
            }
        case .idle, .offering:
            guard !starting else { return }
            guard settings.offerMeetingNotes else {
                if case .offering = phase { setPhase(.idle) }
                return
            }
            let apps = CallDetector.appsUsingMicrophone()
            if apps.isEmpty { seen = nil; declined = nil }
            if case .offering = phase {
                if apps.isEmpty || Date().timeIntervalSince(offeredAt) > 60 { dismissOffer() }
                return
            }
            guard let app = apps.first(where: { $0.bundle != declined }) else { return }
            if seen?.app != app { seen = (app, Date()) }
            if let seen, Date().timeIntervalSince(seen.since) >= Self.noticeCallAfter {
                offeredAt = Date()
                setPhase(.offering(app))
            }
        }
    }

    private func setPhase(_ p: Phase) {
        phase = p
        bar.update()
        onChange()
    }

    /// "Not now": stays quiet until this app lets go of the mic.
    func dismissOffer() {
        if case .offering(let app) = phase { declined = app.bundle }
        setPhase(.idle)
    }

    func neverOffer() {
        settings.offerMeetingNotes = false
        setPhase(.idle)
    }

    // MARK: Recording

    func startRecording() {
        guard phase != .recording, !starting, let store else { return }
        var app: CallDetector.App?
        if case .offering(let a) = phase { app = a }
        let free = (try? Store.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard free > 1_000_000_000 else { flash("Not enough disk space to record"); return }
        starting = true
        Task {
            defer { starting = false }
            let now = Date()
            let title = app.map { $0.name.isEmpty ? "Call" : "Call on \($0.name)" } ?? "Meeting"
            let id = await store.addMeeting(title: title, date: now)
            do {
                try recorder.start(in: Self.audioDir(id), device: AudioDevices.resolve(microphone()))
            } catch {
                recorder.stop()
                await store.deleteMeeting(id)
                try? FileManager.default.removeItem(at: Self.audioDir(id))
                flash("Couldn’t start recording")
                return
            }
            started = now
            elapsed = 0
            callApp = app != nil
            lastCallApp = now
            callAudioMissing = false
            currentID = id
            selectedID = id
            await reload()
            setPhase(.recording)
        }
    }

    func stop() {
        guard phase == .recording, let id = currentID else { return }
        recorder.stop()
        let duration = Date().timeIntervalSince(started)
        currentID = nil
        declined = CallDetector.appsUsingMicrophone().first?.bundle  // stopped by hand mid-call: don't offer again
        seen = nil
        setPhase(.idle)
        saveTyped?.cancel()
        Task {
            await updated(id) { $0.durationS = duration; $0.status = .processing }
            queue.append(id)
            drain()
        }
    }

    /// On quit, closes the audio files so the meeting can be finished on the next launch.
    func stopForQuit() {
        guard phase == .recording else { return }
        recorder.stop()
    }

    func setTyped(_ text: String, id: Int64) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[i].typed = text
        saveTyped?.cancel()
        saveTyped = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let m = meetings.first(where: { $0.id == id }) else { return }
            await store?.saveMeeting(m)
        }
    }

    func setTitle(_ title: String, id: Int64) {
        Task { await updated(id) { $0.title = title } }
    }

    /// Gives a speaker a name everywhere in one meeting: their lines in the transcript, and mentions in the notes.
    func renameSpeaker(_ old: String, to new: String, id: Int64) {
        let name = new.components(separatedBy: CharacterSet(charactersIn: ":[]").union(.newlines)).joined()
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return }
        let mention = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: old))\\b")
        Task {
            await updated(id) { m in
                m.transcript = m.transcript.components(separatedBy: "\n").map { line in
                    guard let close = line.firstIndex(of: "]"), line[line.index(after: close)...].hasPrefix(" \(old):") else { return line }
                    return String(line[...close]) + " \(name):" + line[line.index(close, offsetBy: old.count + 3)...]
                }.joined(separator: "\n")
                if let mention {
                    m.notes = mention.stringByReplacingMatches(in: m.notes, range: NSRange(m.notes.startIndex..., in: m.notes),
                                                               withTemplate: NSRegularExpression.escapedTemplate(for: name))
                }
                if m.you == old { m.you = name }
            }
        }
    }

    func delete(_ id: Int64) {
        guard id != currentID else { return }
        queue.removeAll { $0 == id }
        try? FileManager.default.removeItem(at: Self.audioDir(id))
        meetings.removeAll { $0.id == id }
        if selectedID == id { selectedID = meetings.first?.id }
        Task { await store?.deleteMeeting(id) }
    }

    /// Writes the notes again, or picks up after a failure.
    func retry(_ id: Int64) {
        guard !queue.contains(id), progress[id] == nil else { return }
        Task {
            await updated(id) { $0.status = .processing; $0.problem = "" }
            queue.append(id)
            drain()
        }
    }

    // MARK: After the call

    private func drain() {
        guard !working, !queue.isEmpty else { return }
        working = true
        let id = queue.removeFirst()
        Task {
            await process(id)
            progress[id] = nil
            working = false
            drain()
        }
    }

    private func process(_ id: Int64) async {
        guard let m = meetings.first(where: { $0.id == id }) else { return }
        do {
            if m.transcript.isEmpty { try await makeTranscript(id) }
            guard let m = meetings.first(where: { $0.id == id }), !m.transcript.isEmpty else { return }
            let model = try await notesModel(id)
            progress[id] = "Writing your notes…"
            PersonalTrainer.setPaused(true)  // both want the GPU, and these are the notes you're waiting for
            defer { PersonalTrainer.setPaused(false) }
            let prompt = MeetingPrompt.notes(you: m.you.isEmpty ? nil : m.you,
                                             vocab: m.vocab.isEmpty ? [] : m.vocab.components(separatedBy: "; "),
                                             typed: m.typed, transcript: m.transcript)
            let notes = try await MeetingPipeline.writeNotes(prompt: prompt, model: model)
            await updated(id) { $0.notes = notes; $0.status = .ready; $0.problem = "" }
            flash("Your meeting notes are ready")
        } catch {
            await updated(id) { $0.status = .failed; $0.problem = error.localizedDescription }
        }
    }

    private func makeTranscript(_ id: Int64) async throws {
        let dir = Self.audioDir(id)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path) else {
            throw MeetingError.noAudio
        }
        let t = try await MeetingPipeline.transcribe(dir: dir) { line in
            Task { @MainActor [weak self] in self?.progress[id] = line }
        }
        guard !t.text.isEmpty else {
            try? FileManager.default.removeItem(at: dir)
            throw MeetingError.noSpeech
        }
        await updated(id) {
            $0.transcript = t.text
            $0.you = t.you ?? ""
            $0.vocab = t.vocab.joined(separator: "; ")
        }
        // The transcript is safely saved, so the recording goes now, before the slow part.
        try? FileManager.default.removeItem(at: dir)
    }

    /// The notes model in use, downloading it the first time: the bigger one if you chose it and the Mac can run it.
    private func notesModel(_ id: Int64) async throws -> URL {
        if settings.accurateNotes && ModelStore.canRunAccurateNotes {
            if let dir = ModelStore.installedNotes(accurate: true) { return dir }
            let task = downloadAccurate()
            while modelProgress != nil {  // mirror the shared download's progress onto this meeting
                progress[id] = modelProgress
                try? await Task.sleep(for: .milliseconds(500))
            }
            return try await task.value
        }
        if let dir = ModelStore.installedNotes(accurate: false) { return dir }
        progress[id] = "Downloading the notes model…"
        return try await ModelStore.download(ModelStore.notes, into: ModelStore.notesDirectory) { p in
            Task { @MainActor [weak self] in
                self?.progress[id] = String(format: "Downloading the notes model… %.0f%%", p * 100)
            }
        }
    }

    // MARK: Choosing the notes model

    /// The bigger model's download, shared by Settings, the Meetings page and a meeting waiting for it.
    private(set) var modelProgress: String?
    @ObservationIgnored private var accurateTask: Task<URL, Error>?

    /// Your answer to "Your Mac can run a bigger notes model". Choosing it starts the download straight away.
    func chooseNotesModel(accurate: Bool) {
        settings.notesModelAsked = true
        guard accurate else { settings.accurateNotes = false; return }
        let free = (try? Store.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        if ModelStore.installedNotes(accurate: true) == nil, free < ModelStore.accurateNotes.bytes + 2_000_000_000 {
            flash("The bigger model needs about 17 GB of free disk space")
            return
        }
        settings.accurateNotes = true
        if ModelStore.installedNotes(accurate: true) == nil { _ = downloadAccurate() }
    }

    private func downloadAccurate() -> Task<URL, Error> {
        if let accurateTask { return accurateTask }
        modelProgress = "Downloading the accurate notes model…"
        let task = Task { @MainActor in
            defer { modelProgress = nil; accurateTask = nil }
            do {
                return try await ModelStore.download(ModelStore.accurateNotes, into: ModelStore.notesDirectory) { p in
                    Task { @MainActor [weak self] in
                        guard self?.modelProgress != nil else { return }
                        self?.modelProgress = String(format: "Downloading the accurate notes model… %.0f%%", p * 100)
                    }
                }
            } catch {
                flash("The accurate notes model couldn’t be downloaded")
                throw error
            }
        }
        accurateTask = task
        return task
    }

    enum MeetingError: LocalizedError {
        case noAudio, noSpeech
        var errorDescription: String? {
            switch self {
            case .noAudio: "The recording wasn’t saved."
            case .noSpeech: "No speech was heard in this recording."
            }
        }
    }

    /// Sample data for window snapshots.
    func preview(_ meetings: [Meeting], selected: Int64?, recording: Int64? = nil, progress: [Int64: String] = [:]) {
        self.meetings = meetings
        selectedID = selected
        currentID = recording
        phase = recording == nil ? .idle : .recording
        elapsed = 754
        self.progress = progress
    }
}

/// When a recording stops by itself. Kept apart from the timer so the rules can be checked on their own
/// (MurmurBee --autostop-check).
enum AutoStop {
    struct State: CustomStringConvertible {
        var elapsed: Double
        /// Whether a call app (another app using the mic) was seen during this recording.
        var sawCallApp: Bool
        /// Seconds since a call app last used the mic, since the call audio last had sound, since the mic last did.
        var sinceCallApp: Double
        var sinceCallSound: Double
        var sinceMicSound: Double

        var description: String {
            String(format: "%.0f s in, call app %@ %.0f s ago, call sound %.0f s ago, mic sound %.0f s ago", elapsed,
                   sawCallApp ? "seen," : "never seen,", sinceCallApp, sinceCallSound, sinceMicSound)
        }
    }

    static let longestMeeting = 4 * 3600.0

    static func reason(_ s: State) -> String? {
        if s.elapsed >= longestMeeting { return "four hours" }
        // The call app let go of the mic and the call went quiet: the normal end of a call.
        if s.sawCallApp, s.sinceCallApp >= 15, s.sinceCallSound >= 15 { return "call ended" }
        // The call app let go a while ago but the Mac is still playing something (music, a video).
        if s.sawCallApp, s.sinceCallApp >= 90 { return "call app gone" }
        // Nobody has said anything on either side for three minutes, whatever still holds the mic.
        if s.sinceCallSound >= 180, s.sinceMicSound >= 180 { return "silence" }
        return nil
    }
}

