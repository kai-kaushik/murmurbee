"""M04: bleed filters for the two-channel recording.

Your mic hears the other people (through the room, or through laptop speakers on a real call), and the call audio
can carry your voice back. A word belongs to a channel only if it is clearly louder there than on the other channel.

  level filter  keep a mic word if its level on the mic is at least `t` dB above its level in the call audio
                over the same span; keep a call-audio word if it is at least `t` dB above the mic.
  oracle        keep a mic word only if AMI says you were talking at its midpoint (and a call-audio word only if
                someone else was). Uses the answer key: an upper bound for any filter, never a real system.
"""
import numpy as np
import soundfile as sf

RATE = 16_000


def levels(audio, words):
    out = []
    for w in words:
        seg = audio[int(w["s"] * RATE):max(int(w["e"] * RATE), int(w["s"] * RATE) + 160)]
        out.append(20 * np.log10(np.sqrt(np.mean(seg.astype(np.float64) ** 2)) + 1e-9))
    return np.array(out)


def level_filter(words, own, other, t):
    """Words transcribed from `own` that are at least t dB louder in `own` than in `other`."""
    if not words:
        return []
    diff = levels(own, words) - levels(other, words)
    return [w for w, d in zip(words, diff) if d >= t]


def load(path):
    audio, rate = sf.read(path, dtype="float32")
    assert rate == RATE, path
    return audio


def inside(t, segs):
    return any(s <= t <= e for s, e in segs)


def oracle(words, mine, theirs):
    """Keep words said while `mine` was talking and not only while `theirs` was (midpoint)."""
    return [w for w in words if inside((w["s"] + w["e"]) / 2, mine)]
