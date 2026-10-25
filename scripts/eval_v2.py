"""Compare cleanup models on (1) the 20-clip test set with real context and (2) held-out structure examples.

Usage: python scripts/eval_v2.py <model-or-base> [--adapter DIR] [--prompt v1|v2]
  (1) Test set: input = Parakeet Ultra transcript; v2 also gets vocab (on-screen names + dictionary terms that
      sound like the transcript, as the app picks them) and the text before the cursor. WER vs Kai's final text.
  (2) Held-out v2 validation examples (data/sft2/valid.jsonl), grouped by kind: lists, emails, sign-off chunks,
      quotes, continuations. Reports exact line-structure match and WER.
"""
import argparse
import json
import re
import statistics
import sys
import time

import jiwer
from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler

sys.path.insert(0, "scripts")
from prompt_v2 import SYSTEM, user_message  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("model")
ap.add_argument("--adapter", default=None)
ap.add_argument("--prompt", default="v2", choices=["v1", "v2"])
a = ap.parse_args()

model, tok = load(a.model, adapter_path=a.adapter)
sampler = make_sampler(temp=0.0)
APPS = {"com.anthropic.claudefordesktop": ("Claude", "AI assistant prompt"),
        "com.tinyspeck.slackmacgap": ("Slack", "work chat")}


def gen(user):
    msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}]
    p = tok.apply_chat_template(msgs, tokenize=True, add_generation_prompt=True, enable_thinking=False)
    raw = re.search(r"<transcript>(.*)</transcript>", user, re.S).group(1)
    t, out = time.perf_counter(), ""
    for r in stream_generate(model, tok, p, max_tokens=int(len(raw.split()) * 2.1) + 24, sampler=sampler):
        out += r.text
    return out.strip(), (time.perf_counter() - t) * 1000


def words(s):
    return " ".join(jiwer.RemovePunctuation()(s.lower()).split())


def similar(a, b):
    import difflib
    return difflib.SequenceMatcher(None, a, b).ratio()


def select_vocab(raw, screen, dictionary):
    """Python mirror of Vocabulary.select in the app."""
    ws = re.findall(r"[a-z0-9]+", raw.lower())
    def near(term):
        t = re.sub(r"[^a-z0-9]", "", term.lower())
        if len(t) < 3:
            return False
        n = len(term.split())
        return any((w := "".join(ws[i:i + n])) == t or (w[:1] == t[:1] and similar(w, t) >= 0.6)
                   for i in range(max(len(ws) - n + 1, 0)))
    out = []
    for t in screen[:8] + [d for d in dictionary if near(d)]:
        if t not in out:
            out.append(t)
    return out[:12]


# (1) test set
dictionary = [l.strip() for l in open("data/vocab.txt") if l.strip()]
ctx = {json.loads(l)["transcriptEntityId"]: json.loads(l) for l in open("data/wispr-golden/audio.jsonl")}
ultra = {json.loads(l)["id"]: json.loads(l)["text"] for l in open("data/asr_ultra.jsonl")}
rows = [json.loads(l) for l in open("data/testset.jsonl")]
res = []
for r in rows:
    raw = ultra[r["transcriptEntityId"]]
    app = APPS.get(r["app"], ("unknown", "general"))
    c = ctx.get(r["transcriptEntityId"], {})
    if a.prompt == "v2":
        screen = json.loads(c.get("axContext") or "[]")
        u = user_message(app[0], app[1], raw, select_vocab(raw, screen, dictionary), c.get("beforeText") or "")
    else:
        u = f"app={app[0]} type={app[1]}\n<transcript>{raw}</transcript>"
    out, ms = gen(u)
    res.append((r["bucket"], jiwer.wer(words(r["finalText"]), words(out)), jiwer.wer(words(r["finalText"]), words(raw)), ms))
print("TEST SET (Parakeet input, vs Kai's final text)")
for b in ["short", "med", "long", "xl", "ALL"]:
    rs = [x for x in res if b == "ALL" or x[0] == b]
    print(f"  {b:5} n={len(rs):2}  WER {statistics.mean(x[1] for x in rs):.3f}  (raw {statistics.mean(x[2] for x in rs):.3f})"
          f"  p50 {statistics.median(x[3] for x in rs):.0f} ms")

# (2) structure, held out
if a.prompt == "v2":
    kinds = {"self-correction": [], "list": [], "list continuation": [], "email": [], "sign-off chunk": [],
             "quote": [], "continuation": []}
    cue = re.compile(r"\b(no wait|wait no|sorry|correct that|scratch that|or rather|i mean|no,? actually)\b", re.I)
    for l in open("data/sft2/valid.jsonl"):
        m = json.loads(l)["messages"]
        u, t = m[1]["content"], m[2]["content"]
        has_before = "<before>" in u
        raw_in = re.search(r"<transcript>(.*)</transcript>", u, re.S).group(1)
        if cue.search(raw_in) and not cue.search(t):
            kinds["self-correction"].append((u, t))
            continue
        if re.search(r"(^|\n)(\d+\.|-) ", t):
            k = "list continuation" if has_before else "list"
        elif "type=email" in u and re.search(r"\n\n\w[\w ]*,\nKai", "\n\n" + t):
            k = "sign-off chunk" if has_before and len(t) < 30 else "email"
        elif '"' in t and "quote" in u:
            k = "quote"
        elif has_before:
            k = "continuation"
        else:
            continue
        kinds[k].append((u, t))
    print("\nSTRUCTURE (held-out examples): exact line layout / WER")
    for k, xs in kinds.items():
        xs = xs[:25]
        if not xs:
            continue
        layout, w = 0, []
        for u, t in xs:
            out, _ = gen(u)
            shape = lambda s: re.sub(r"[^\n]+", "x", s.strip())
            layout += shape(out) == shape(t)
            w.append(jiwer.wer(words(t), words(out)) if words(t) else 0)
        print(f"  {k:18} n={len(xs):2}  layout {layout}/{len(xs)}  WER {statistics.mean(w):.3f}")
