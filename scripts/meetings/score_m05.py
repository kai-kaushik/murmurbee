"""Aggregate M05 referee verdicts: coverage and unsupported rate per notes model x transcript."""
import json, sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "bench/meetings/m05"
REF = sys.argv[1] if len(sys.argv) > 1 else "gemma-4-26b-a4b-it-4bit"
SECTIONS = ("abstract", "decisions", "actions", "problems")

rows, out = [], {}
for model in sorted(p.name for p in ROOT.iterdir() if p.is_dir()):
    for cond in ("gold", "pipeline"):
        f = ROOT / model / cond / f"referee-{REF}.json"
        if not f.exists():
            continue
        d = json.load(open(f))
        cov, sec, cl, unparsed = Counter(), {s: Counter() for s in SECTIONS}, Counter(), 0
        per_meeting = []
        for m, r in d.items():
            mc = Counter()
            for it in r["items"]:
                v = it["verdict"]
                if v.startswith("unparsed"):
                    unparsed += 1
                    continue
                cov[v] += 1; mc[v] += 1
                sec.setdefault(it["section"], Counter())[v] += 1
            for c in r["claims"]:
                v = c["verdict"]
                if v.startswith("unparsed"):
                    unparsed += 1
                    continue
                cl[v] += 1
            n = sum(mc.values())
            per_meeting.append((mc["yes"] + 0.5 * mc["partly"]) / n if n else 0)
        score = lambda c: (c["yes"] + 0.5 * c["partly"]) / max(1, sum(c.values()))
        res = {
            "meetings": len(d),
            "coverage": score(cov),
            "coverage_strict": cov["yes"] / max(1, sum(cov.values())),
            "partly_share": cov["partly"] / max(1, sum(cov.values())),
            "sections": {s: score(c) for s, c in sec.items() if sum(c.values())},
            "claims": sum(cl.values()),
            "unsupported": cl["unsupported"] / max(1, sum(cl.values())),
            "unparsed": unparsed,
            "per_meeting": per_meeting,
        }
        out[f"{model}/{cond}"] = res
        rows.append((model, cond, res))

print(f"referee: {REF}")
print("| Notes model | Transcript | Coverage | yes only | abstract | decisions | actions | problems | Claims | Unsupported |")
print("|---|---|---|---|---|---|---|---|---|---|")
for model, cond, r in rows:
    s = r["sections"]
    print(f"| {model} | {cond} | {r['coverage']:.0%} | {r['coverage_strict']:.0%} | "
          + " | ".join(f"{s.get(k, float('nan')):.0%}" for k in SECTIONS)
          + f" | {r['claims']} | {r['unsupported']:.0%} |")
json.dump(out, open(ROOT / f"scores-{REF}.json", "w"), indent=1)
