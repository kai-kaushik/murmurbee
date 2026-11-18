"""M07 results: live notes (streaming speech recognition + live speaker labels) against the batch pipeline (M01).

Rows pair a transcript (batch Parakeet Ultra from M01, or a streaming Parakeet Unified tier) with speaker labels
(the batch offline diarizer, Sortformer high-context ~30 s behind, or the live Sortformer configs ~1 s and ~2 s
behind). Word latency = how much audio had been fed when the word appeared, minus the word's end time (the model's
own delay; compute per 80 ms step is reported separately in the logs).

usage: evaluate_m07.py
"""
import json
import statistics as st
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from score_words import attribute, load_rttm, pooled, score, seglst  # noqa: E402

BENCH = Path(__file__).resolve().parents[2] / "bench/meetings"
M01, M07 = BENCH / "m01", BENCH / "m07"
ASR = {"batch Parakeet Ultra": None, "live Unified 2080 ms": "unified-2080", "live Unified 1120 ms": "unified-1120",
       "live Unified 320 ms": "unified-320"}
DIAR = {"batch offline": M01 / "offline", "Sortformer, ~30 s behind": M01 / "sortformer",
        "live Sortformer, ~2 s behind": M07 / "sortformer-efficient",
        "live Sortformer, ~1 s behind": M07 / "sortformer-balanced"}


def words_for(asr, meeting):
    path = M01 / f"asr/{meeting}.words.json" if asr is None else M07 / asr / f"{meeting}.json"
    return json.loads(path.read_text())["words"] if path.exists() else None


def main():
    meetings = sorted(p.stem for p in (M01 / "offline").glob("*.rttm"))
    results, latency = {}, {}
    for a_name, asr in ASR.items():
        all_words = {m: words_for(asr, m) for m in meetings}
        if any(w is None for w in all_words.values()):
            continue
        if asr:
            lag = [w["emit"] - w["e"] for ws in all_words.values() for w in ws]
            q = st.quantiles(lag, n=10)
            latency[a_name] = {"median": st.median(lag), "p90": q[-1], "words": len(lag)}
        for d_name, d in DIAR.items():
            if not all((d / f"{m}.rttm").exists() for m in meetings):
                continue
            rows = [score(m, seglst(m, attribute(all_words[m], load_rttm(d / f"{m}.rttm")))) for m in meetings]
            results[f"{a_name} | {d_name}"] = pooled(rows)
    (M07 / "results.json").write_text(json.dumps({"words": results, "latency": latency}, indent=1))
    print("| Transcript | Speakers | WER | cpWER |\n|---|---|---|---|")
    for k, r in results.items():
        print(f"| {k} | {r['orc_wer']:.1%} | {r['cpwer']:.1%} |")
    print("\n| Transcript | words | median delay | 90th percentile |\n|---|---|---|---|")
    for k, r in latency.items():
        print(f"| {k} | {r['words']} | {r['median']:.2f} s | {r['p90']:.2f} s |")


if __name__ == "__main__":
    main()
