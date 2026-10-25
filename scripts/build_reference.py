"""Build a neutral 'answer key' from raw audio by majority vote of three ASR systems.

Systems: Wispr raw ASR (from the export), Parakeet Ultra (data/asr_ultra.jsonl), Qwen3-ASR-1.7B (run here).
For each clip, words where at least two systems agree become the reference; the rest are listed as
disputes for Kai to settle by ear (data/reference/disputes.jsonl, with clip time offsets).

Usage: python scripts/build_reference.py [n_clips]   (default 10: 3 short, 4 medium, 3 long)
"""
import json
import pathlib
import re
import sys
import time
from difflib import SequenceMatcher

import jiwer
from mlx_qwen3_asr import load_model, transcribe

N = int(sys.argv[1]) if len(sys.argv) > 1 else 10
OUT = pathlib.Path("data/reference")
OUT.mkdir(exist_ok=True)
FILLERS = re.compile(r"\b(um+|uh+|erm|hmm+|ah)\b")


def words(s):
    s = jiwer.RemovePunctuation()(s.lower().replace("-", " "))
    return FILLERS.sub(" ", s).split()


rows = [json.loads(l) for l in open("data/testset.jsonl")]
quota = {"short": 3, "med": 4, "long": 3} if N == 10 else {"short": N, "med": N, "long": N}
picked, seen = [], {}
for r in rows:
    if seen.get(r["bucket"], 0) < quota.get(r["bucket"], 0):
        picked.append(r)
        seen[r["bucket"]] = seen.get(r["bucket"], 0) + 1
ultra = {json.loads(l)["id"]: json.loads(l)["text"] for l in open("data/asr_ultra.jsonl")}

model = load_model("Qwen/Qwen3-ASR-1.7B")
model = model[0] if isinstance(model, tuple) else model
qwen = {}
for r in picked:
    t = time.perf_counter()
    res = transcribe(f"data/wispr-golden/{r['audioPath']}", model=model, language="English")
    qwen[r["transcriptEntityId"]] = res.text
    print(f"qwen3-asr {r['bucket']:5} {r['duration']:5.1f}s audio in {time.perf_counter() - t:5.2f}s")


def vote(a, b, c):
    """Align b and c to a (the pivot); return reference tokens and disputed spans."""
    ref, disputes = [], []
    mb = SequenceMatcher(None, a, b, autojunk=False)
    mc = SequenceMatcher(None, a, c, autojunk=False)
    # map each pivot index -> aligned word in b / c (None if not equal-aligned)
    def mapping(m, other):
        mp = {}
        for tag, i1, i2, j1, j2 in m.get_opcodes():
            if tag == "equal":
                for k in range(i2 - i1):
                    mp[i1 + k] = other[j1 + k]
        return mp
    eb, ec = mapping(mb, b), mapping(mc, c)
    i = 0
    while i < len(a):
        if i in eb or i in ec:  # pivot word agrees with at least one other system
            ref.append(a[i])
            i += 1
            continue
        j = i
        while j < len(a) and j not in eb and j not in ec:
            j += 1
        disputes.append({"pivot_span": (i, j), "pivot": " ".join(a[i:j])})
        ref.extend(a[i:j])  # provisional; Kai settles these
        i = j
    return ref, disputes


summary = []
with open(OUT / "reference.jsonl", "w") as fr, open(OUT / "disputes.jsonl", "w") as fd:
    for r in picked:
        rid = r["transcriptEntityId"]
        w, u, q = words(r["asrText"]), words(ultra[rid]), words(qwen[rid])
        # Pivot = the system closest to the other two, so the vote is not biased toward any one source.
        cands = {"wispr": w, "ultra": u, "qwen": q}
        def spread(k):
            return sum(jiwer.wer(" ".join(cands[o]), " ".join(cands[k])) for o in cands if o != k)
        pivot = min(cands, key=spread)
        others = [k for k in cands if k != pivot]
        ref, disp = vote(cands[pivot], cands[others[0]], cands[others[1]])
        dur = r["duration"]
        for d in disp:  # rough time offset by word position, to find the snippet quickly
            i, _ = d["pivot_span"]
            d.update(id=rid, audioPath=r["audioPath"], approx_second=round(dur * i / max(len(cands[pivot]), 1), 1),
                     pivot_system=pivot, **{k: None for k in others})
            fd.write(json.dumps(d, ensure_ascii=False) + "\n")
        fr.write(json.dumps({"id": rid, "bucket": r["bucket"], "reference": " ".join(ref), "pivot": pivot,
                             "wispr": " ".join(w), "ultra": " ".join(u), "qwen": " ".join(q),
                             "n_disputes": len(disp)}, ensure_ascii=False) + "\n")
        summary.append((r["bucket"], len(ref), len(disp)))

ref = {json.loads(l)["id"]: json.loads(l) for l in open(OUT / "reference.jsonl")}
print(f"\n{len(picked)} clips, {sum(s[1] for s in summary)} reference words, {sum(s[2] for s in summary)} disputed spans")
print("WER vs majority-vote reference (provisional until disputes are settled):")
for k in ["wispr", "ultra", "qwen"]:
    print(f"  {k:6} {jiwer.wer([v['reference'] for v in ref.values()], [v[k] for v in ref.values()]):.3f}")
