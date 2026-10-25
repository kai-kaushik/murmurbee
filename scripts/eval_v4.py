"""E13+: like eval_v3, plus --prompt v3 (full context), --chunked (clean the transcript in pieces with the
already-written text as <before>, joined like the app), and suites for names, sign-offs and spoken times.
A v2-prompt model scored on v3 suites gets the v3-only lines stripped, so each model sees its own format.

Based on: E12+: score a cleanup model on a locked split (data/splits.json): --split dev|test.
Clips: that split's audio clips (Parakeet Ultra transcript in, WER vs Kai's final text, with a bootstrap 95% CI).
Suites: data/sft3/<split>_suites.jsonl (held-out sentence pool). Writes a JSON summary with --json.

Based on eval_v2: compare cleanup models on (1) the 20-clip test set with real context and (2) held-out structure examples.

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
import prompt_v3  # noqa: E402
from datetime import datetime, timedelta  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("model")
ap.add_argument("--adapter", default=None)
ap.add_argument("--prompt", default="v2", choices=["v1", "v2", "v3"])
ap.add_argument("--chunked", action="store_true")
ap.add_argument("--suites", default="data/sft3")
ap.add_argument("--split", default="dev", choices=["dev", "test"])
ap.add_argument("--json", default=None)
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


import os
LIMIT = int(os.environ.get('LIMIT', 10**9))
# (1) test set
dictionary = [l.strip() for l in open("data/vocab.txt") if l.strip()]
ctx = {json.loads(l)["transcriptEntityId"]: json.loads(l) for l in open("data/wispr-golden/audio.jsonl")}
ultra = {}
for f in ("data/asr_ultra_all.jsonl", "data/asr_ultra.jsonl"):
    ultra.update({json.loads(l)["id"]: json.loads(l)["text"] for l in open(f)})
ids = set(json.load(open("data/splits.json"))[a.split])
def bucket(d):
    return "short" if d < 8 else "med" if d < 30 else "long" if d < 90 else "xl"
rows = []
for r in ctx.values():
    if r["transcriptEntityId"] in ids and r["transcriptEntityId"] in ultra and r.get("asrText"):
        r["bucket"] = bucket(r["duration"] or 0)
        r["finalText"] = r.get("editedText") or r.get("pastedText") or r.get("formattedText") or ""
        if r["finalText"]:
            rows.append(r)
res = []
for r in rows[:LIMIT]:
    raw = ultra[r["transcriptEntityId"]]
    app = APPS.get(r["app"], ("unknown", "general"))
    c = ctx.get(r["transcriptEntityId"], {})
    screen = json.loads(c.get("axContext") or "[]")
    vocab = select_vocab(raw, screen, dictionary)
    def build(piece, before):
        if a.prompt == "v3":
            off = c.get("timezoneOffsetMinutes")
            kw = {"user": "Kai Kaushik", "locale": "en-GB", "url": prompt_v3.clean_url(c.get("url")),
                  "after": c.get("afterText") or ""}
            if off is not None:
                utc = datetime.fromisoformat(c["timestamp"].replace(" +00:00", "+00:00").replace(" ", "T"))
                kw["tz"] = prompt_v3.tz_label(off)
                kw["time"] = (utc - timedelta(minutes=int(off))).strftime("%a %d %b %Y %H:%M")
            return prompt_v3.user_message(app[0], app[1], piece, vocab, before, **kw)
        if a.prompt == "v2":
            return user_message(app[0], app[1], piece, vocab, before)
        return f"app={app[0]} type={app[1]}\n<transcript>{piece}</transcript>"
    if a.chunked:
        # Pieces of ~25 words cut at sentence ends: roughly what pause-based chunking gives the app.
        sents = re.split(r"(?<=[.?!])\s+", raw.strip())
        pieces, cur = [], ""
        for snt in sents:
            if cur and len((cur + " " + snt).split()) > 25:
                pieces.append(cur); cur = snt
            else:
                cur = (cur + " " + snt).strip()
        if cur: pieces.append(cur)
        written, ms = "", 0.0
        for k, piece in enumerate(pieces):
            o, t = gen(build(piece, written or (c.get("beforeText") or "")))
            written = prompt_v3.join(written, o, app[1])
            ms = t  # latency of the last piece is what the user waits for
        out = written
    else:
        out, ms = gen(build(raw, c.get("beforeText") or ""))
    res.append((r["bucket"], jiwer.wer(words(r["finalText"]), words(out)), jiwer.wer(words(r["finalText"]), words(raw)), ms))
import random as _r
def ci(vals, n=1000):
    rr = _r.Random(0); m = len(vals)
    bs = sorted(statistics.mean(rr.choice(vals) for _ in range(m)) for _ in range(n))
    return bs[int(0.025 * n)], bs[int(0.975 * n)]
summary = {"split": a.split, "clips": {}, "suites": {}}
print(f"{a.split.upper()} CLIPS (Parakeet input, vs Kai's final text), n={len(res)}")
for b in ["short", "med", "long", "xl", "ALL"]:
    rs = [x for x in res if b == "ALL" or x[0] == b]
    if not rs:
        continue
    w = [x[1] for x in rs]
    lo, hi = ci(w)
    summary["clips"][b] = {"n": len(rs), "wer": statistics.mean(w), "ci": [lo, hi],
                           "raw": statistics.mean(x[2] for x in rs)}
    print(f"  {b:5} n={len(rs):2}  WER {statistics.mean(w):.3f} [{lo:.3f}, {hi:.3f}]  (raw {statistics.mean(x[2] for x in rs):.3f})"
          f"  p50 {statistics.median(x[3] for x in rs):.0f} ms")

# (2) structure, held out
if a.prompt == "v2":
    kinds = {"name fix": [], "sign-off misheard": [], "spoken time": [], "correction then more": [], "self-correction": [], "list": [], "list continuation": [], "email": [], "sign-off chunk": [],
             "quote": [], "continuation": []}
    cue = re.compile(r"\b(no wait|wait no|sorry|correct that|scratch that|or rather|i mean|no,? actually)\b", re.I)
    for l in open(f"{a.suites}/{a.split}_suites.jsonl"):
        m = json.loads(l)["messages"]
        u, t = m[1]["content"], m[2]["content"]
        if a.prompt != "v3":  # strip v3-only context so a v2 model sees its own format
            u = "\n".join(x for x in u.split("\n") if not re.match(r"^(user=|locale=|tz=|url=)", x))
            u = re.sub(r"<(selected|after)>.*?</\1>\n?", "", u, flags=re.S)
        has_before = "<before>" in u
        raw_in = re.search(r"<transcript>(.*)</transcript>", u, re.S).group(1)
        vocab_line = re.search(r"^vocab: (.*)$", u, re.M)
        vocab_terms = vocab_line.group(1).split("; ") if vocab_line else []
        if any(v in t and v not in raw_in and v.lower() not in raw_in.lower() for v in vocab_terms if v[:1].isupper() and " " not in v and v != "Kai"):
            kinds["name fix"].append((u, t)); continue
        if re.search(r"\b(regards?|thanks|cheers)\b[ .,]*(hi|sky|guy|kay|chi|kite|car|pie|high|kye)\.?$", raw_in, re.I) and t.endswith(",\nKai"):
            kinds["sign-off misheard"].append((u, t)); continue
        if re.search(r"\b\d{1,2} \d{2}\b", raw_in) and re.search(r"\d:\d{2}", t):
            kinds["spoken time"].append((u, t)); continue
        if cue.search(raw_in) and not cue.search(t) and len(t.split()) > 9:
            kinds["correction then more"].append((u, t)); continue
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
        xs = xs[:min(40, LIMIT)]
        if not xs:
            continue
        layout, w = 0, []
        for u, t in xs:
            out, _ = gen(u)
            shape = lambda s: re.sub(r"[^\n]+", "x", s.strip())
            layout += shape(out) == shape(t)
            w.append(jiwer.wer(words(t), words(out)) if words(t) else 0)
        summary["suites"][k] = {"n": len(xs), "layout": layout, "wer": statistics.mean(w)}
        print(f"  {k:18} n={len(xs):2}  layout {layout}/{len(xs)}  WER {statistics.mean(w):.3f}")
if a.json:
    json.dump(summary, open(a.json, "w"), indent=1)
