"""M08: coverage of chunk-then-merge notes vs a single pass, paired over meetings, with notes length and time.

usage: score_m08.py dev|test [REF]
dev   compares bench/meetings/m08/dev/chunk{0,5,10,20}
test  compares m08/test/chunkN/{gold,pipeline} with M05's single pass (m05/Qwen3.5-4B-4bit/{gold,pipeline})
"""
import json, random, statistics, sys
from pathlib import Path

BENCH = Path(__file__).resolve().parents[2] / "bench/meetings"
STAGE = sys.argv[1]
REF = sys.argv[2] if len(sys.argv) > 2 else "gemma-4-26b-a4b-it-4bit"


def coverage(f):
    d = json.load(open(f / f"referee-{REF}.json"))
    out = {}
    for m, r in d.items():
        v = [it["verdict"] for it in r["items"] if not it["verdict"].startswith("unparsed")]
        out[m] = (v.count("yes") + 0.5 * v.count("partly")) / len(v)
    return out


def extras(f):
    words = {p.stem: len(p.read_text().split()) for p in f.glob("*.md") if not p.stem.endswith(".parts")}
    wall = {r["meeting"]: r["wall_s"] for r in map(json.loads, open(f / "timings.jsonl")) if "meeting" in r}
    return words, wall


def boot(diffs, n=10000, seed=0):
    rng = random.Random(seed)
    means = sorted(statistics.mean(rng.choices(diffs, k=len(diffs))) for _ in range(n))
    return means[int(0.025 * n)], means[int(0.975 * n)]


if STAGE == "dev":
    arms = {f"chunk{n}": BENCH / f"m08/dev/chunk{n}" for n in (0, 5, 10, 20)}
    pairs = [(a, "chunk0") for a in arms if a != "chunk0"]
else:
    n = sys.argv[3] if len(sys.argv) > 3 else "10"
    arms = {}
    for cond in ("gold", "pipeline"):
        arms[f"single/{cond}"] = BENCH / f"m05/Qwen3.5-4B-4bit/{cond}"
        arms[f"chunk{n}/{cond}"] = BENCH / f"m08/test/chunk{n}/{cond}"
    pairs = [(f"chunk{n}/{c}", f"single/{c}") for c in ("gold", "pipeline")]

cov = {a: coverage(f) for a, f in arms.items()}
ext = {a: extras(f) for a, f in arms.items()}
# meeting length from the single-pass transcript tokens, to split shorter/longer halves
base = pairs[0][1]
tokens = {r["meeting"]: r["prompt_tokens"] for r in map(json.loads, open(arms[base] / "timings.jsonl")) if "meeting" in r}
order = sorted(tokens, key=tokens.get)
short, long_ = set(order[: len(order) // 2]), set(order[len(order) // 2:])

print(f"referee: {REF}\n")
print("| Arm | Coverage | shorter half | longer half | median notes words | median time (s) |")
print("|---|---|---|---|---|---|")
for a in arms:
    c, (w, t) = cov[a], ext[a]
    print(f"| {a} | {statistics.mean(c.values()):.0%} | {statistics.mean(c[m] for m in short):.0%} | "
          f"{statistics.mean(c[m] for m in long_):.0%} | {statistics.median(w.values()):.0f} | {statistics.median(t.values()):.0f} |")
print()
for a, b in pairs:
    for name, ms in (("all", order), ("shorter", sorted(short)), ("longer", sorted(long_))):
        d = [100 * (cov[a][m] - cov[b][m]) for m in ms]
        lo, hi = boot(d)
        print(f"{a} - {b} [{name}]: {statistics.mean(d):+.1f} ({lo:+.1f} to {hi:+.1f})")
    print("  per meeting:", " ".join(f"{m}:{100 * (cov[a][m] - cov[b][m]):+.0f}" for m in order))
    ta, tb = ext[a][1], ext[b][1]
    print(f"  time ratio (total): {sum(ta.values()) / sum(tb.values()):.2f}x")
