import Foundation

/// Capture readiness depends on arriving audio, not AVAudioEngine.isRunning.
struct CaptureHealth {
    enum Status: Equatable { case starting, recording, failed }
    let startedAt: TimeInterval
    private(set) var firstBufferAt: TimeInterval?
    private(set) var lastBufferAt: TimeInterval?
    private var steadySince: TimeInterval?
    private var steadyFrames = 0
    private var hasBeenReady = false

    init(startedAt: TimeInterval) { self.startedAt = startedAt }

    mutating func receive(frames: Int, at now: TimeInterval) {
        guard frames > 0 else { return }
        if firstBufferAt == nil { firstBufferAt = now }
        if steadySince == nil || lastBufferAt == nil || now - lastBufferAt! > 0.6 {
            steadySince = now
            steadyFrames = 0
        }
        lastBufferAt = now
        steadyFrames += frames
        if steadyFrames >= 8000, now - (steadySince ?? now) >= 0.2 { hasBeenReady = true }
    }

    mutating func configurationChanged() {
        steadySince = nil
        steadyFrames = 0
    }

    func status(at now: TimeInterval) -> Status {
        if !hasBeenReady, now - startedAt >= 5 { return .failed }
        guard let lastBufferAt else { return .starting }
        if now - lastBufferAt >= 4 { return .failed }
        guard now - lastBufferAt < 0.6, let steadySince,
              steadyFrames >= 8000, now - steadySince >= 0.2 else { return .starting }
        return .recording
    }
}
