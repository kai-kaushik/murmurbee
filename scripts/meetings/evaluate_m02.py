"""M02 results: the simulated call (your mic on its own channel) vs one mixed channel (M01).

For each call (meeting, you):
  - every word transcribed from the mic channel is labelled "you";
  - words transcribed from the others channel get the speaker the others-channel diarization says;
  - DER uses "you" turns built from the mic words (pauses over 0.5 s split a turn) plus that diarization.
Bleed, counted against AMI's speaker turns by each word's midpoint:
  mic bleed     mic-channel words said only while someone else was talking (credited to you by mistake)
  others echo   others-channel words said only while you were talking (your voice leaking into the call audio)
M01 is re-pooled with each meeting weighted by its number of calls, so both columns cover the same audio.

usage: evaluate_m02.py [--filter none|oracle|level:<dB>] [--dev] [--no-m01] ENGINE [ENGINE...]
  --filter  bleed filter applied to both channels' words before scoring (bleed.py, M04)
  --dev     the 12 AMI dev meetings (bench/meetings/m02_dev), for choosing a filter threshold
"""
import argparse
import json
import sys
import warnings
from pathlib import Path

from pyannote.core import Annotation, Segment
from pyannote.metrics.diarization import DiarizationErrorRate

sys.path.insert(0, str(Path(__file__).parent))
import bleed as bl  # noqa: E402
import score_words  # noqa: E402
from score_der import CONVENTIONS, load_rttm as load_ann, load_uem  # noqa: E402
from score_words import attribute, load_rttm, pooled, score as words_score, seglst  # noqa: E402

warnings.filterwarnings("ignore")
BENCH = Path(__file__).resolve().parents[2] / "bench/meetings"
AMI = Path.home() / "FluidAudioDatasets/ami_official"
M02, REF, CALLS = BENCH / "m02", AMI / "ref", AMI / "calls"


def turns(words, gap=0.5):
    out = []
    for w in sorted(words, key=lambda w: w["s"]):
        if out and w["s"] - out[-1][1] <= gap:
            out[-1][1] = max(out[-1][1], w["e"])
        else:
            out.append([w["s"], w["e"]])
    return out


def inside(t, segs):
    return any(s <= t <= e for s, e in segs)


def ref_turns(meeting):
    by = {}
    for line in (REF / "rttm" / f"{meeting}.rttm").read_text().splitlines():
        f = line.split()
        by.setdefault(f[7], []).append((float(f[3]), float(f[3]) + float(f[4])))
    return by


def bleed(words, mine, theirs):
    mids = [(w["s"] + w["e"]) / 2 for w in words]
    return sum(1 for t in mids if inside(t, theirs) and not inside(t, mine)), len(mids)


def der_metrics():
    return {k: DiarizationErrorRate(**v) for k, v in CONVENTIONS.items()}


def der_pooled(metrics):
    s = metrics["strict"]
    tot = {k: sum(c[k] for _, c in s.results_) for k in ("total", "missed detection", "false alarm", "confusion")}
    return {**{k: abs(m) for k, m in metrics.items()}, "miss": tot["missed detection"] / tot["total"],
            "fa": tot["false alarm"] / tot["total"], "confusion": tot["confusion"] / tot["total"]}


def apply_filter(name, meeting, you, mic, oth, mine, theirs):
    if name == "none":
        return mic, oth
    if name == "oracle":
        return bl.oracle(mic, mine, theirs), bl.oracle(oth, theirs, mine)
    t = float(name.split(":")[1])
    a_mic, a_oth = bl.load(CALLS / f"{meeting}.{you}.mic.wav"), bl.load(CALLS / f"{meeting}.{you}.others.wav")
    return bl.level_filter(mic, a_mic, a_oth, t), bl.level_filter(oth, a_oth, a_mic, t)


def evaluate(engine, filt="none"):
    metrics, word_rows, mic_bleed, echo = der_metrics(), [], [0, 0], [0, 0]
    calls = sorted(M02.glob(f"{engine}/*.others.rttm"))
    for path in calls:
        meeting, you = path.name.split(".")[:2]
        mic = json.loads((M02 / f"asr/{meeting}.{you}.mic.words.json").read_text())["words"]
        oth = json.loads((M02 / f"asr/{meeting}.{you}.others.words.json").read_text())["words"]
        rt = ref_turns(meeting)
        mine = rt.get(you, [])
        theirs = [seg for k, v in rt.items() if k != you for seg in v]
        mic, oth = apply_filter(filt, meeting, you, mic, oth, mine, theirs)
        diar = [(s, e, f"o_{k}") for s, e, k in load_rttm(path)]
        words = [{**w, "spk": "you"} for w in mic] + attribute(oth, diar)
        word_rows.append(words_score(meeting, seglst(meeting, words)))

        hyp = Annotation(uri=meeting)
        for s, e in turns(mic):
            hyp[Segment(s, e), len(hyp)] = "you"
        for s, e, k in diar:
            if e > s:
                hyp[Segment(s, e), len(hyp)] = k
        ref, uem = load_ann(REF / "rttm" / f"{meeting}.rttm"), load_uem(REF / "uem" / f"{meeting}.uem")
        for m in metrics.values():
            m(ref, hyp, uem=uem)

        b, n = bleed(mic, mine, theirs)
        mic_bleed = [mic_bleed[0] + b, mic_bleed[1] + n]
        b, n = bleed(oth, theirs, mine)
        echo = [echo[0] + b, echo[1] + n]
    return {"calls": len(calls), "der": der_pooled(metrics), "words": pooled(word_rows),
            "mic_bleed": mic_bleed[0] / mic_bleed[1], "others_echo": echo[0] / echo[1]}


def m01_weighted(engine):
    """M01 on the same footing: each meeting counted once per call built from it."""
    m01 = BENCH / "m01"
    weights = {}
    for p in M02.glob(f"{engine}/*.others.rttm"):
        weights[p.name.split(".")[0]] = weights.get(p.name.split(".")[0], 0) + 1
    metrics, rows = der_metrics(), []
    for meeting, n in weights.items():
        ref, uem = load_ann(REF / "rttm" / f"{meeting}.rttm"), load_uem(REF / "uem" / f"{meeting}.uem")
        hyp = load_ann(m01 / engine / f"{meeting}.rttm")
        words = json.loads((m01 / f"asr/{meeting}.words.json").read_text())["words"]
        row = words_score(meeting, seglst(meeting, attribute(words, load_rttm(m01 / engine / f"{meeting}.rttm"))))
        for _ in range(n):
            for m in metrics.values():
                m(ref, hyp, uem=uem)
            rows.append(row)
    return {"der": der_pooled(metrics), "words": pooled(rows)}


def main():
    global M02, REF, CALLS
    ap = argparse.ArgumentParser()
    ap.add_argument("engines", nargs="+")
    ap.add_argument("--filter", default="none")
    ap.add_argument("--dev", action="store_true")
    ap.add_argument("--no-m01", action="store_true")
    a = ap.parse_args()
    if a.dev:
        M02, REF, CALLS = BENCH / "m02_dev", AMI / "dev/ref", AMI / "dev/calls"
        score_words.REFS = BENCH / "refs_dev"
    results = {}
    for engine in a.engines:
        results[engine] = {"m02": evaluate(engine, a.filter)}
        if not a.no_m01:
            results[engine]["m01"] = m01_weighted(engine)
    tag = a.filter.replace(":", "_")
    (M02 / f"results_{tag}.json").write_text(json.dumps(results, indent=1))
    print("| Diarizer | Audio | DER comparable | DER strict | miss | false alarm | confusion | WER | cpWER |")
    print("|---|---|---|---|---|---|---|---|---|")
    for engine, r in results.items():
        for label, key in (("one mixed channel (M01)", "m01"), (f"mic + call audio, filter={a.filter}", "m02")):
            if key not in r:
                continue
            d, w = r[key]["der"], r[key]["words"]
            print(f"| {engine} | {label} | {d['comparable']:.1%} | {d['strict']:.1%} | {d['miss']:.1%} | {d['fa']:.1%} "
                  f"| {d['confusion']:.1%} | {w['orc_wer']:.1%} | {w['cpwer']:.1%} |")
    for engine, r in results.items():
        m = r["m02"]
        print(f"\n{engine}: {m['calls']} calls; mic bleed {m['mic_bleed']:.1%} of mic words, "
              f"others echo {m['others_echo']:.1%} of call-audio words")


if __name__ == "__main__":
    main()
