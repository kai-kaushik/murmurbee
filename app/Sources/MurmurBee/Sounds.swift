import AppKit

/// Short, quiet cues: one when recording starts, another when you let go and it's processing, a softer one on cancel.
@MainActor
enum Sounds {
    enum Cue { case start, stop, cancel }

    private static let sounds: [Cue: NSSound] = {
        var out: [Cue: NSSound] = [:]
        for (cue, name, volume) in [(Cue.start, "Tink", Float(0.25)), (.stop, "Pop", 0.3), (.cancel, "Bottle", 0.15)] {
            if let s = NSSound(named: NSSound.Name(name))?.copy() as? NSSound {
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
