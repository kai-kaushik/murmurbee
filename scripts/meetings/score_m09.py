"""M09 scores: coverage (referee.py) and faithfulness (faithful.py) per notes model, from the Qwen3.5-35B-A3B
referee, plus notes length and time. Differences against Qwen3.5 4B are paired by meeting (bootstrap 95%).

usage: score_m09.py            prints the tables, writes bench/meetings/m09/scores.json
       score_m09.py --sample N writes a blind hand-check sample (N flagged + N supported, across models) to
                               bench/meetings/m09/handcheck.json, with the key to which model wrote what kept apart
"""
import json
import random
import statistics
import sys
from collections import Counter
from pathlib import Path

import numpy as np

BENCH = Path(__file__).resolve().parents[2] / "bench/meetings"
REF = "Qwen3.5-35B-A3B-4bit"
MODELS = {"Qwen3.5 4B": BENCH / "m05/Qwen3.5-4B-4bit/pipeline",
          "Poodle 4B": BENCH / "m09/Underdog-Poodle-4B/pipeline",
          "Gemma 4 26B-A4B": BENCH / "m09/gemma-4-26b-a4b-it-4bit/pipeline",
          "Saluki 27B": BENCH / "m09/Underdog-Saluki-27B-IQ2/pipeline"}
BASE = "Qwen3.5 4B"


def coverage(items):
    v = Counter(i["verdict"] for i in items if not i["verdict"].startswith("unparsed"))
    return (v["yes"] + 0.5 * v["partly"]) / max(1, sum(v.values()))


def boot(diffs, n=10000, seed=0):
    rng = np.random.default_rng(seed)
    d = np.array(diffs)
    means = rng.choice(d, (n, len(d))).mean(1)
    return d.mean(), np.percentile(means, 2.5), np.percentile(means, 97.5)


def load(d):
    cov = json.loads((d / f"referee-{REF}.json").read_text())
    fai = json.loads((d / f"faithful-{REF}.json").read_text())
    t = [json.loads(l) for l in (d / "timings.jsonl").read_text().splitlines()]
    t = {r["meeting"]: r for r in t if "meeting" in r}
    words = {m: len((d / f"{m}.md").read_text().split()) for m in cov}
    return cov, fai, t, words


def main():
    data = {k: load(d) for k, d in MODELS.items()}
    if "--sample" in sys.argv:
        return sample(data, int(sys.argv[sys.argv.index("--sample") + 1]))
    out = {}
    print("| Notes model | Coverage | abstract | decisions | actions | problems | Statements | Unsupported | Unclear | "
          "Quote found (supported) | Median words | Median time |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for k, (cov, fai, t, words) in data.items():
        items = [i for m in cov for i in cov[m]["items"]]
        sec = {s: coverage([i for i in items if i["section"] == s]) for s in ("abstract", "decisions", "actions", "problems")}
        cl = [c for m in fai for c in fai[m]["claims"]]
        v = Counter(c["verdict"] for c in cl)
        sup = [c for c in cl if c["verdict"] == "supported"]
        qf = sum(c["quote_found"] is True for c in sup) / max(1, len(sup))
        res = {"coverage": coverage(items), "sections": sec, "statements": len(cl),
               "unsupported": v["unsupported"] / len(cl), "unclear": v["unclear"] / len(cl),
               "unparsed": sum(x.startswith("unparsed") for x in v.elements()), "quote_found": qf,
               "median_words": statistics.median(words.values()),
               "median_s": statistics.median(r["wall_s"] for r in t.values()),
               "per_meeting": {m: coverage(cov[m]["items"]) for m in cov},
               "unsupported_per_meeting": {m: sum(c["verdict"] == "unsupported" for c in fai[m]["claims"])
                                           / max(1, len(fai[m]["claims"])) for m in fai}}
        out[k] = res
        print(f"| {k} | {res['coverage']:.0%} | " + " | ".join(f"{x:.0%}" for x in sec.values())
              + f" | {len(cl)} | {res['unsupported']:.0%} | {res['unclear']:.0%} | {qf:.0%} | "
              f"{res['median_words']:.0f} | {res['median_s']:.0f} s |")
    print("\nPaired by meeting against", BASE, "(mean, 95% bootstrap):")
    for k in out:
        if k == BASE:
            continue
        for metric in ("per_meeting", "unsupported_per_meeting"):
            ms = sorted(out[k][metric])
            m, lo, hi = boot([100 * (out[k][metric][x] - out[BASE][metric][x]) for x in ms])
            out[k][f"diff_{metric}"] = [m, lo, hi]
            print(f"  {k} {'coverage' if metric == 'per_meeting' else 'unsupported'}: {m:+.1f} ({lo:+.1f} to {hi:+.1f})")
    (BENCH / "m09/scores.json").write_text(json.dumps(out, indent=1))


def sample(data, n):
    rng = random.Random(0)
    pools = {"unsupported": [], "supported": []}
    for k, (cov, fai, t, words) in data.items():
        for m, r in fai.items():
            for c in r["claims"]:
                if c["verdict"] in pools:
                    pools[c["verdict"]].append({"model": k, "meeting": m, **c})
    picked = []
    for v, pool in pools.items():  # the same number from each model where possible
        by = {k: [c for c in pool if c["model"] == k] for k in data}
        for k in by:
            rng.shuffle(by[k])
        i = 0
        while len([p for p in picked if p["verdict"] == v]) < n and any(by.values()):
            k = list(by)[i % len(by)]
            if by[k]:
                picked.append(by[k].pop())
            i += 1
    rng.shuffle(picked)
    blind = [{"id": i, "meeting": p["meeting"], "statement": p["renamed"]} for i, p in enumerate(picked)]
    key = [{"id": i, "model": p["model"], "verdict": p["verdict"], "quote": p["quote"]} for i, p in enumerate(picked)]
    (BENCH / "m09/handcheck.json").write_text(json.dumps(blind, indent=1))
    (BENCH / "m09/handcheck_key.json").write_text(json.dumps(key, indent=1))
    print(len(blind), "statements written")


if __name__ == "__main__":
    main()
