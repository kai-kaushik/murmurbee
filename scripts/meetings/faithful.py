"""M09 (M05b's design): is each statement in the notes supported by the meeting? One statement at a time, with only
the transcript passages most related to it, and the referee must copy a supporting line before it answers.

M05's referee read the whole transcript for every statement and its "unsupported" flags were right only 29-57% of the
time (hand check). Here:
  - passages: the manual transcript cut into windows of six turns (stride three), ranked by BM25 against the
    statement, top four kept, shown in time order
  - speakers: notes written from the pipeline transcript number speakers by the pipeline's diarizer, so "Speaker N"
    in a statement is renamed to the manual transcript's speaker with the most words in common (Hungarian
    assignment on time overlap); statements about who said what are then checkable
  - answer: "Quote: <up to 25 words, or NONE>" then "Verdict: supported | unsupported | unclear"; greedy, thinking off
A quote whose content words aren't in one passage line is recorded (quote_found=False) but the verdict is kept as given.

usage: faithful.py REFEREE_MODEL NOTES_DIR [NOTES_DIR ...]   (pipeline notes; writes <NOTES_DIR>/faithful-<model>.json)
"""
import json
import math
import re
import sys
from collections import Counter
from pathlib import Path

import mlx.core as mx
import numpy as np
from mlx_lm import load, generate
from mlx_lm.sample_utils import make_sampler
from scipy.optimize import linear_sum_assignment

sys.path.insert(0, str(Path(__file__).parent))
from referee import claims  # noqa: E402
from score_words import attribute, load_rttm, normalise  # noqa: E402
from summarise import BENCH, MEETINGS, label_speakers, render  # noqa: E402

PROMPT = """You are checking one statement from notes about a meeting. Below are the parts of the meeting's \
transcript most related to the statement (not the whole transcript; "..." marks a gap). Speakers in the statement are \
labelled the same way as in the transcript.

Transcript passages:
{passages}

Statement: {claim}

First copy the words from the transcript that best support the statement (at most 25 words in a row, exactly as \
written, without the time or speaker), or write NONE if nothing supports it. Then give your verdict: supported (it was said or clearly follows from what was said), unsupported (it \
contradicts the transcript, or adds a detail such as a name, number, date, decision or owner that was not said), or \
unclear (these passages are not enough to tell).

Answer in exactly this form:
Quote: <the words, or NONE>
Verdict: <supported, unsupported or unclear>"""

STOP = set("""a an the and or but of to in on at for with by from as is are was were be been being it its this that
these those there their they them he she we you i speaker speakers will would should could can may might also not no
do does did have has had which who what when where how than then so such into about over all any some more most very
just one two discussed mentioned said noted suggested team group meeting notes""".split())


def toks(text):
    """Content words for BM25, after Whisper's normaliser, so "twenty five Euro" and "25 euros" match."""
    out = []
    for w in re.findall(r"[a-z0-9]+", normalise(text)):
        if w in STOP or (len(w) < 3 and not w.isdigit()):
            continue
        for suf in ("ing", "ed", "es", "s"):
            if len(w) > len(suf) + 3 and w.endswith(suf):
                w = w[: -len(suf)]
                break
        out.append(w)
    return out


class Passages:
    def __init__(self, lines, size=6, stride=3, top=4):
        self.lines, self.top = lines, top
        self.windows = [list(range(i, min(i + size, len(lines)))) for i in range(0, max(1, len(lines) - size + stride), stride)]
        self.docs = [Counter(t for j in w for t in toks(lines[j])) for w in self.windows]
        self.avg = sum(sum(d.values()) for d in self.docs) / len(self.docs)
        df = Counter(t for d in self.docs for t in d)
        n = len(self.docs)
        self.idf = {t: math.log(1 + (n - c + 0.5) / (c + 0.5)) for t, c in df.items()}

    def __call__(self, claim, k1=1.2, b=0.75):
        q = set(toks(claim))
        def score(d):
            L = sum(d.values())
            return sum(self.idf.get(t, 0) * d[t] * (k1 + 1) / (d[t] + k1 * (1 - b + b * L / self.avg)) for t in q if t in d)
        best = sorted(range(len(self.docs)), key=lambda i: -score(self.docs[i]))[: self.top]
        keep = sorted({j for i in best for j in self.windows[i]})
        out, prev = [], None
        for j in keep:
            if prev is not None and j != prev + 1:
                out.append("...")
            out.append(self.lines[j])
            prev = j
        return "\n".join(out)


def speaker_map(pipe_words, gold_words):
    """Pipeline label -> manual label, by the most time-overlapping words (one-to-one)."""
    gold = sorted(gold_words, key=lambda w: w["s"])
    starts = [w["s"] for w in gold]
    import bisect
    count = Counter()
    for w in pipe_words:
        mid = (w["s"] + w["e"]) / 2
        i = bisect.bisect_right(starts, mid) - 1
        for g in gold[max(0, i - 3): i + 1]:
            if g["s"] <= mid <= g["e"]:
                count[(w["spk"], g["spk"])] += 1
                break
    ps = sorted({w["spk"] for w in pipe_words})
    gs = sorted({w["spk"] for w in gold_words})
    m = np.array([[count[(p, g)] for g in gs] for p in ps])
    rows, cols = linear_sum_assignment(-m)
    return {ps[r]: gs[c] for r, c in zip(rows, cols) if m[r, c] > 0}


def rename(text, mapping):
    return re.sub(r"Speaker (\d+)", lambda m: mapping.get(f"Speaker {m.group(1)}", "an unidentified speaker"), text)


def parse(answer):
    quote = re.search(r"Quote:\s*(.*)", answer)
    verdict = re.search(r"Verdict:\s*\**\s*(supported|unsupported|unclear)", answer, re.I)
    return (quote.group(1).strip() if quote else ""), (verdict.group(1).lower() if verdict else "unparsed:" + answer[-60:])


def found(quote, passages):
    if not quote or quote.upper().startswith("NONE"):
        return None
    q = " ".join(toks(re.sub(r"^\[\d\d:\d\d\]\s*(Speaker \d+:)?", "", quote)))
    return any(q in " ".join(toks(l)) for l in passages.splitlines())


def main():
    model_id, dirs = sys.argv[1], [Path(d) for d in sys.argv[2:]]
    mx.set_cache_limit(1 << 30)
    model, tok = load(model_id)
    sampler = make_sampler(temp=0.0)
    name = model_id.rstrip("/").split("/")[-1]
    out = {d: d / f"faithful-{name}.json" for d in dirs}
    rows = {d: json.loads(out[d].read_text()) if out[d].exists() else {} for d in dirs}  # resume
    for meeting in MEETINGS:
        if all(meeting in rows[d] for d in dirs):
            continue
        gold = label_speakers(json.loads((BENCH / f"refs/{meeting}.json").read_text())["words"])
        asr = json.loads((BENCH / f"m01/asr/{meeting}.words.json").read_text())["words"]
        pipe = label_speakers(attribute(asr, load_rttm(BENCH / f"m01/offline/{meeting}.rttm")))
        mapping = speaker_map(pipe, gold)
        retrieve = Passages(render(gold).splitlines())
        for d in dirs:
            if meeting in rows[d]:
                continue
            res = []
            for c in claims((d / f"{meeting}.md").read_text()):
                claim = rename(c, mapping)
                passages = retrieve(claim)
                prompt = tok.apply_chat_template([{"role": "user", "content": PROMPT.format(passages=passages, claim=claim)}],
                                                 add_generation_prompt=True, enable_thinking=False)
                answer = generate(model, tok, prompt, max_tokens=200, sampler=sampler).strip()
                quote, verdict = parse(answer)
                res.append({"text": c, "renamed": claim, "quote": quote, "quote_found": found(quote, passages),
                            "verdict": verdict})
            rows[d][meeting] = {"speaker_map": mapping, "claims": res}
            v = Counter(r["verdict"] for r in res)
            print(meeting, d.parent.name, dict(v), flush=True)
            out[d].write_text(json.dumps(rows[d], indent=1))


if __name__ == "__main__":
    main()
