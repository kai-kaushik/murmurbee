import AppKit

/// Short, quiet cues: one when recording starts, another when you let go and it's processing, a softer one on cancel.
@MainActor
enum Sounds {
    enum Cue { case start, stop, cancel }

    /// MurmurBee's own soft chimes (scripts/make_sounds.py), bundled in Resources/sounds.
    private static let sounds: [Cue: NSSound] = {
        var out: [Cue: NSSound] = [:]
        for (cue, name, volume) in [(Cue.start, "start", Float(0.55)), (.stop, "stop", 0.55), (.cancel, "cancel", 0.5)] {
            if let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds"),
               let s = NSSound(contentsOf: url, byReference: false) {
                s.volume = volume
                out[cue] = s
            }
        }
        return out
    }()

    static func play(_ cue: Cue) {
        guard Settings.shared.playSounds, let s = sounds[cue] else { return }
        s.stop()
        s.play()
    }
}
