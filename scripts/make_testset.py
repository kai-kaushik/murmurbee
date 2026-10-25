"""Pick a small, length-stratified test set from the Wispr golden export.

Usage: python scripts/make_testset.py [n_short n_med n_long n_xl]
Writes data/testset.jsonl. Same seed -> same set, so runs stay comparable.
"""
import json
import random
import sys

counts = [int(x) for x in sys.argv[1:5]] if len(sys.argv) >= 5 else [6, 7, 5, 2]
buckets = {"short": (0, 8), "med": (8, 30), "long": (30, 90), "xl": (90, 1e9)}

rows = [json.loads(l) for l in open("data/wispr-golden/audio.jsonl")]
rows = [r for r in rows if (r["detectedLanguage"] or r["language"] or "").startswith("en") and r["asrText"]]
rng = random.Random(42)

picked = []
for (name, (lo, hi)), n in zip(buckets.items(), counts):
    pool = [r for r in rows if lo <= (r["duration"] or 0) < hi]
    for r in rng.sample(pool, min(n, len(pool))):
        r["bucket"] = name
        # Kai's final text: his edit if he made one, else what was pasted, else Wispr's formatting.
        r["finalText"] = r["editedText"] or r["pastedText"] or r["formattedText"]
        picked.append(r)

with open("data/testset.jsonl", "w") as f:
    for r in picked:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
print(f"{len(picked)} clips, {sum(r['duration'] for r in picked):.0f} s of audio -> data/testset.jsonl")
