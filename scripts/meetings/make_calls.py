"""Simulated calls for M02: each participant in turn plays "you".

  <meeting>.<speaker>.mic.wav     that participant's own headset (what MurmurBee would record from the mic)
  <meeting>.<speaker>.others.wav  everyone else's headsets summed (what the call app plays back)

AMI headsets are close-talking but pick up nearby people, so the mic channel holds some of the others (and the
others channel some of "you"). A real call has less of this when you wear headphones, more when you don't (M04).
Only headsets that belong to an annotated speaker are used (EN2002c has three).
"""
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

DEV = "--dev" in sys.argv  # the 12 dev meetings, for tuning the bleed filter
AMI = Path.home() / "FluidAudioDatasets/ami_official" / ("dev" if DEV else "")
REFS = Path(__file__).resolve().parents[2] / ("bench/meetings/refs_dev" if DEV else "bench/meetings/refs")
OUT = AMI / "calls"


def main():
    OUT.mkdir(exist_ok=True)
    for ref in sorted(REFS.glob("*.seglst.json")):
        meeting = ref.name.split(".")[0]
        speakers = json.loads((REFS / f"{meeting}.json").read_text())["speakers"]
        heads = {s: sf.read(AMI / f"ihm_all/{meeting}.Headset-{v['headset']}.wav", dtype="float32")
                 for s, v in speakers.items()}
        rate = {r for _, r in heads.values()}.pop()
        n = min(len(a) for a, _ in heads.values())
        for you in speakers:
            mic = heads[you][0][:n]
            others = sum(a[:n] for s, (a, _) in heads.items() if s != you)
            peak = float(np.abs(others).max())
            if peak > 0.99:  # summing can clip; scale down, never up
                others = others * (0.99 / peak)
            sf.write(OUT / f"{meeting}.{you}.mic.wav", mic, rate, subtype="PCM_16")
            sf.write(OUT / f"{meeting}.{you}.others.wav", others, rate, subtype="PCM_16")
        print(meeting, len(speakers), "calls", f"{n / rate / 60:.1f} min")


if __name__ == "__main__":
    main()
