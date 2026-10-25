"""Lock the train / dev / test splits for every experiment from E12 on. Writes data/splits.json.

  test  : every audio clip recorded on or after TEST_FROM (time split: newer than anything trained on).
          Only scored at milestones and for published numbers.
  dev   : the original 20-clip set plus DEV_EXTRA more clips from before TEST_FROM, stratified by length.
          Used to choose between checkpoints and models.
  train : everything else, minus near-duplicates (similarity > 0.8) of any dev or test clip.
Sentence pools for synthetic behaviour suites are split by content hash: ~85% train, ~7.5% dev, ~7.5% test.
"""
import difflib
import hashlib
import json
import random
import re

TEST_FROM = "2026-10-23"
DEV_EXTRA = 60
rng = random.Random(2026)


def norm(s):
    return " ".join(re.sub(r"[^a-z0-9 ]", " ", (s or "").lower()).split())


audio = [json.loads(l) for l in open("data/wispr-golden/audio.jsonl")]
text = [json.loads(l) for l in open("data/wispr-golden/text.jsonl")]
english = lambda r: (r.get("detectedLanguage") or r.get("language") or "en").startswith("en") and r.get("asrText")

test = [r["transcriptEntityId"] for r in audio if english(r) and r["timestamp"][:10] >= TEST_FROM]
dev = [json.loads(l)["transcriptEntityId"] for l in open("data/testset.jsonl")]
pool = [r for r in audio if english(r) and r["timestamp"][:10] < TEST_FROM and r["transcriptEntityId"] not in dev]
buckets = {"short": (0, 8), "med": (8, 30), "long": (30, 90), "xl": (90, 1e9)}
quota = {"short": 18, "med": 22, "long": 15, "xl": 5}
for b, (lo, hi) in buckets.items():
    cands = [r for r in pool if lo <= (r["duration"] or 0) < hi]
    dev += [r["transcriptEntityId"] for r in rng.sample(cands, min(quota[b], len(cands)))]

held = {r["transcriptEntityId"]: norm(r["asrText"]) for r in audio if r["transcriptEntityId"] in set(dev) | set(test)}
held_texts = list(held.values())


def near_dup(t):
    for h in held_texts:
        if abs(len(h) - len(t)) < 0.3 * len(h) + 5 and difflib.SequenceMatcher(None, t, h).quick_ratio() > 0.8 \
                and difflib.SequenceMatcher(None, t, h).ratio() > 0.8:
            return True
    return False


excluded = set(dev) | set(test)
near = [r["transcriptEntityId"] for r in text if r["transcriptEntityId"] not in excluded and near_dup(norm(r["asrText"]))]


def sentence_split(key):
    h = int(hashlib.sha1(key.encode()).hexdigest(), 16) % 40
    return "dev" if h < 3 else "test" if h < 6 else "train"


json.dump({"test_from": TEST_FROM, "test": test, "dev": dev, "near_duplicates_removed": near,
           "sentence_pool_rule": "sha1(target) % 40: 0-2 dev, 3-5 test, else train"},
          open("data/splits.json", "w"), indent=1)
print(f"test {len(test)} clips (from {TEST_FROM}), dev {len(dev)} clips, near-duplicates removed from train: {len(near)}")
