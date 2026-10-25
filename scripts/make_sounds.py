"""Synthesise MurmurBee's interface sounds: soft, rounded chimes instead of the stock macOS ones.
start  : a gentle rising two-tone "bloop" (recording begins)
stop   : its falling mirror, a touch longer (you let go; processing)
cancel : a single low, muted tick
Each: sine with soft harmonics, a fast-but-not-clicky attack, exponential decay, gentle low-pass, and a few
early reflections for air. Peak around -16 dBFS; the app plays them quietly on top of that."""
import pathlib
import wave
import numpy as np

SR = 48_000
OUT = pathlib.Path("app/Resources/sounds")


def tone(f0, f1, dur, tau, glide=0.07, partials=((1, 1.0), (2, 0.22), (3, 0.07), (4, 0.03))):
    t = np.arange(int(SR * dur)) / SR
    freq = f1 + (f0 - f1) * np.exp(-t / (glide / 3))  # quick glide from f0 to f1
    phase = 2 * np.pi * np.cumsum(freq) / SR
    x = sum(a * np.sin(k * phase) for k, a in partials)
    env = (1 - np.exp(-t / 0.004)) * np.exp(-t / tau)  # 4 ms attack, exponential decay
    return x * env


def soften(x, cutoff=5200):
    a = np.exp(-2 * np.pi * cutoff / SR)  # one-pole low-pass
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def air(x):
    y = np.concatenate([x, np.zeros(int(SR * 0.08))])
    for ms, g in [(11, 0.18), (23, 0.12), (37, 0.08), (53, 0.05)]:
        d = int(SR * ms / 1000)
        y[d:d + len(x)] += g * x
    return y


def write(name, x, peak_db=-16):
    x = air(soften(x))
    fade = int(SR * 0.01)
    x[-fade:] *= np.linspace(1, 0, fade)
    x = x / np.max(np.abs(x)) * 10 ** (peak_db / 20)
    data = (x * 32767).astype(np.int16)
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(data.tobytes())


OUT.mkdir(parents=True, exist_ok=True)
# start: two notes a fourth apart, the second rising (E5 -> A5), overlapping slightly
s = np.zeros(int(SR * 0.26))
a = tone(640, 659.3, 0.20, 0.055); s[:len(a)] += a
b = tone(840, 880.0, 0.20, 0.07); off = int(SR * 0.055); s[off:off + len(b)] += 0.85 * b
write("start", s)
# stop: the mirror, falling (A5 -> E5), slightly longer and warmer
s = np.zeros(int(SR * 0.30))
a = tone(900, 880.0, 0.20, 0.06); s[:len(a)] += 0.85 * a
b = tone(680, 659.3, 0.24, 0.09); off = int(SR * 0.06); s[off:off + len(b)] += b
write("stop", s)
# cancel: one low, muted tick
write("cancel", tone(360, 329.6, 0.12, 0.035, partials=((1, 1.0), (2, 0.1))), peak_db=-20)
print("wrote", sorted(p.name for p in OUT.glob("*.wav")))
