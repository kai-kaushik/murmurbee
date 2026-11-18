"""Diarization error rate for a folder of hypothesis RTTMs against the AMI references.

Three conventions (see docs/MEETING-EXPERIMENTS.md, rule 2):
  comparable  ±0.25 s collar, overlapped speech not scored (how FluidAudio and most AMI tables report)
  strict      ±0.25 s collar, overlap scored (what a user sees)
  full        no collar, overlap scored (pyannote's published AMI numbers)

pyannote.metrics' `collar` is the total width removed around each boundary, so ±0.25 s is collar=0.5.
Totals are pooled over all scored time (not an average of per-meeting rates).

usage: score_der.py HYP_DIR [--ref REF_DIR] [--uem UEM_DIR] [--json OUT]
"""
import argparse
import json
import sys
import warnings
from pathlib import Path

from pyannote.core import Annotation, Segment, Timeline
from pyannote.metrics.diarization import DiarizationErrorRate

warnings.filterwarnings("ignore")
REF = Path.home() / "FluidAudioDatasets/ami_official/ref"
CONVENTIONS = {"comparable": dict(collar=0.5, skip_overlap=True),
               "strict": dict(collar=0.5, skip_overlap=False),
               "full": dict(collar=0.0, skip_overlap=False)}


def load_rttm(path):
    ann = Annotation(uri=path.stem)
    for line in path.read_text().splitlines():
        f = line.split()
        if len(f) >= 8 and f[0] == "SPEAKER":
            start, dur = float(f[3]), float(f[4])
            if dur > 0:
                ann[Segment(start, start + dur), len(ann)] = f[7]
    return ann


def load_uem(path):
    return Timeline([Segment(float(f[2]), float(f[3]))
                     for f in (l.split() for l in path.read_text().splitlines()) if len(f) >= 4])


def score(hyp_dir, ref_dir=REF / "rttm", uem_dir=REF / "uem"):
    metrics = {k: DiarizationErrorRate(**v) for k, v in CONVENTIONS.items()}
    per_file = {}
    for ref_path in sorted(Path(ref_dir).glob("*.rttm")):
        hyp_path = Path(hyp_dir) / ref_path.name
        if not hyp_path.exists():
            continue
        ref, hyp, uem = load_rttm(ref_path), load_rttm(hyp_path), load_uem(Path(uem_dir) / f"{ref_path.stem}.uem")
        row = {}
        for name, m in metrics.items():
            d = m(ref, hyp, uem=uem, detailed=True)
            row[name] = d["diarization error rate"]
            if name == "strict":
                total = d["total"]
                row.update(miss=d["missed detection"] / total, fa=d["false alarm"] / total,
                           confusion=d["confusion"] / total)
        row["speakers_ref"], row["speakers_hyp"] = len(ref.labels()), len(hyp.labels())
        per_file[ref_path.stem] = row
    pooled = {name: abs(m) for name, m in metrics.items()}
    s = metrics["strict"]
    tot = {"total": 0.0, "missed detection": 0.0, "false alarm": 0.0, "confusion": 0.0}
    for _, comps in s.results_:
        for k in tot:
            tot[k] += comps[k]
    pooled.update(miss=tot["missed detection"] / tot["total"], fa=tot["false alarm"] / tot["total"],
                  confusion=tot["confusion"] / tot["total"],
                  correct_speaker_count=sum(r["speakers_ref"] == r["speakers_hyp"] for r in per_file.values()),
                  files=len(per_file))
    return per_file, pooled


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("hyp_dir")
    ap.add_argument("--ref", default=REF / "rttm")
    ap.add_argument("--uem", default=REF / "uem")
    ap.add_argument("--json")
    a = ap.parse_args()
    per_file, pooled = score(a.hyp_dir, a.ref, a.uem)
    print(f"{'meeting':10} {'comp':>6} {'strict':>6} {'full':>6} {'miss':>6} {'fa':>6} {'conf':>6}  spk")
    for name, r in per_file.items():
        print(f"{name:10} {r['comparable']:6.1%} {r['strict']:6.1%} {r['full']:6.1%} {r['miss']:6.1%} "
              f"{r['fa']:6.1%} {r['confusion']:6.1%}  {r['speakers_hyp']}/{r['speakers_ref']}")
    p = pooled
    print(f"{'POOLED':10} {p['comparable']:6.1%} {p['strict']:6.1%} {p['full']:6.1%} {p['miss']:6.1%} "
          f"{p['fa']:6.1%} {p['confusion']:6.1%}  {p['correct_speaker_count']}/{p['files']} right count")
    if a.json:
        Path(a.json).write_text(json.dumps({"per_file": per_file, "pooled": pooled}, indent=1))


if __name__ == "__main__":
    sys.exit(main())
