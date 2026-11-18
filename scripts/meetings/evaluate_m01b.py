"""M01b: does snapping speaker changes to pauses (snap.py) lower cpWER on the mixed channel?

The window is chosen on the 12 dev meetings (m01_dev), then the chosen window is applied once to the 16 test
meetings (m01). WER is unchanged by construction (only labels move), so only cpWER is reported.

usage: evaluate_m01b.py --dev [ENGINE...]            sweep windows on dev
       evaluate_m01b.py --window W [ENGINE...]       one window on test (and window 0 alongside it)
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import score_words  # noqa: E402
from score_words import attribute, load_rttm, pooled, score, seglst  # noqa: E402
from snap import snap  # noqa: E402

BENCH = Path(__file__).resolve().parents[2] / "bench/meetings"
WINDOWS = (0, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0)


def cpwer(run, engine, window):
    rows = []
    for rttm in sorted((run / engine).glob("*.rttm")):
        m = rttm.stem
        words = json.loads((run / f"asr/{m}.words.json").read_text())["words"]
        rows.append(score(m, seglst(m, snap(attribute(words, load_rttm(rttm)), window))))
    return pooled(rows)["cpwer"], len(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("engines", nargs="*", default=["offline", "sortformer"])
    ap.add_argument("--dev", action="store_true")
    ap.add_argument("--window", type=float)
    a = ap.parse_args()
    if a.dev:
        run, windows = BENCH / "m01_dev", WINDOWS
        score_words.REFS = BENCH / "refs_dev"
    else:
        run, windows = BENCH / "m01", (0, a.window)
    results = {e: {w: cpwer(run, e, w) for w in windows} for e in a.engines}
    print("| Diarizer | meetings | " + " | ".join(f"window {w} s" for w in windows) + " |")
    print("|---|---|" + "---|" * len(windows))
    for e, r in results.items():
        print(f"| {e} | {r[windows[0]][1]} | " + " | ".join(f"{r[w][0]:.1%}" for w in windows) + " |")
    out = BENCH / f"m01b_{'dev' if a.dev else 'test'}.json"
    out.write_text(json.dumps({e: {str(w): v[0] for w, v in r.items()} for e, r in results.items()}, indent=1))


if __name__ == "__main__":
    main()
