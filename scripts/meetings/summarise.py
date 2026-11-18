"""M05: meeting summaries from a local LLM (MLX, 4-bit).

Two transcripts per meeting, so summary mistakes can be split from transcript mistakes:
  gold      AMI's manual transcript, speakers as "Speaker 1..N" (no names or roles; the app wouldn't know them)
  pipeline  what the app would have: Parakeet Ultra + offline diarizer on the mixed channel (M01), same labels
Only the 12 scenario meetings have human summaries (the four EN2002 meetings don't).
Greedy decoding (temperature 0) so every run is reproducible; Qwen's thinking mode off; one fixed prompt for all.

usage: summarise.py MODEL_ID [--condition gold|pipeline] [--dev] [--chunk-minutes N] [--out DIR]
Writes bench/meetings/m05/<model>/<condition>/<meeting>.md and timings.jsonl (prompt tokens, prefill and
generation speed, wall time, peak memory).

M08 adds --chunk-minutes: the transcript is cut at turn boundaries into N-minute parts, each part gets its own
notes (same four sections), and a final pass merges the part notes into one set of notes without seeing the
transcript again. --dev uses the dev meetings (for choosing N) instead of the test meetings.

M09 adds --server URL: an OpenAI-style chat server (llama.cpp's llama-server) instead of MLX, for GGUF models.
Same prompt, greedy, thinking off; prompt and generation speeds come from the server's own timings.
"""
import argparse
import json
import time
import urllib.request
from pathlib import Path
from types import SimpleNamespace

import mlx.core as mx
from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler

BENCH = Path(__file__).resolve().parents[2] / "bench/meetings"
MEETINGS = [f"{s}{x}" for s in ("ES2004", "IS1009", "TS3003") for x in "abcd"]
DEV_MEETINGS = [f"{s}{x}" for s in ("ES2011", "IS1008", "TS3004") for x in "abcd"]

PROMPT = """Below is the transcript of a meeting. Speakers are labelled Speaker 1, Speaker 2, and so on, and each line \
starts with the time it was said.

Write meeting notes in Markdown with exactly these four sections:

## Summary
A short paragraph on what the meeting was about and what happened.

## Decisions
Bullet points: what the group agreed or decided. Write "None" if nothing was decided.

## Action items
Bullet points: who will do what next, if stated. Write "None" if there are none.

## Open questions and problems
Bullet points: problems raised or questions left open. Write "None" if there are none.

Only include what the transcript supports. Do not guess names, dates or numbers that were not said.

Transcript:
{transcript}"""

SECTIONS_SPEC = PROMPT.split("Write meeting notes in Markdown with exactly these four sections:\n\n")[1].split(
    "\n\nOnly include")[0]

CHUNK_PROMPT = """Below is part {i} of {n} of a meeting transcript (minutes {start} to {end}). Speakers are labelled \
Speaker 1, Speaker 2, and so on, and each line starts with the time it was said.

Write notes on this part only, in Markdown with exactly these four sections:

""" + SECTIONS_SPEC + """

Only include what this part of the transcript supports. Do not guess names, dates or numbers that were not said.

Transcript part {i} of {n}:
{transcript}"""

MERGE_PROMPT = """Below are notes on the {n} consecutive parts of one meeting, in order. Combine them into notes for \
the whole meeting, in Markdown with exactly these four sections:

""" + SECTIONS_SPEC + """

Merge points that repeat across parts into one. If a later part changes something decided earlier, keep the later \
version. Keep every distinct decision, action item and problem. Do not add anything that is not in the part notes.

{parts}"""

# M08b (a): a merge that only removes repeats, so the overview and every part's points survive.
DEDUP_PROMPT = """Below are notes on the {n} consecutive parts of one meeting, in order. Combine them into notes for \
the whole meeting, in Markdown with exactly these four sections:

""" + SECTIONS_SPEC + """

For the Summary, write one paragraph that walks through the meeting in order, with something from every part. For \
the other sections, keep every bullet from the part notes; only merge bullets that say the same thing, and if a \
later part changes something decided earlier, keep the later version. An action item is something someone will do \
after the meeting, not something they did during it. Do not add anything that is not in the part notes.

{parts}"""

# M08b (b): one pass asked for notes as thorough as the part notes, to separate length from splitting.
THOROUGH = """

Be thorough: cover every topic, presentation and discussion in the order they came up, and how each one ended."""


def label_speakers(words):
    order = {}
    for w in sorted(words, key=lambda w: w["s"]):
        order.setdefault(w["spk"], f"Speaker {len(order) + 1}")
    return [{**w, "spk": order[w["spk"]]} for w in words]


def render(words, gap=1.0):
    """One line per turn: [mm:ss] Speaker N: text. A turn ends when the speaker changes or pauses > gap s."""
    lines, cur = [], None
    for w in sorted(words, key=lambda w: w["s"]):
        if cur and w["spk"] == cur["spk"] and w["s"] - cur["e"] <= gap:
            cur["text"].append(w["w"])
            cur["e"] = w["e"]
        else:
            cur = {"spk": w["spk"], "s": w["s"], "e": w["e"], "text": [w["w"]]}
            lines.append(cur)
    return "\n".join(f"[{int(l['s'] // 60):02d}:{int(l['s'] % 60):02d}] {l['spk']}: {' '.join(l['text'])}"
                     for l in lines)


def transcript(meeting, condition, dev=False):
    refs, m01 = ("refs_dev", "m01_dev") if dev else ("refs", "m01")
    if condition == "gold":
        words = json.loads((BENCH / f"{refs}/{meeting}.json").read_text())["words"]
    else:
        import sys
        sys.path.insert(0, str(Path(__file__).parent))
        from score_words import attribute, load_rttm
        asr = json.loads((BENCH / f"{m01}/asr/{meeting}.words.json").read_text())["words"]
        words = attribute(asr, load_rttm(BENCH / f"{m01}/offline/{meeting}.rttm"))
    return render(label_speakers(words))


def chunks(text, minutes):
    """Cut a rendered transcript at turn boundaries into parts of about `minutes` each: (start, end, text)."""
    parts, cur, limit = [], [], minutes * 60
    for line in text.splitlines():
        t = int(line[1:3]) * 60 + int(line[4:6])
        if cur and t >= limit:
            parts.append(cur)
            cur, limit = [], limit + minutes * 60
            while t >= limit:  # a long silence can skip a whole part
                limit += minutes * 60
        cur.append((t, line))
    if cur:
        parts.append(cur)
    return [(p[0][0] // 60, p[-1][0] // 60 + 1, "\n".join(l for _, l in p)) for p in parts]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--condition", default="gold", choices=["gold", "pipeline"])
    ap.add_argument("--meetings", nargs="*", default=MEETINGS)
    ap.add_argument("--out", help="output folder (default bench/meetings/m05/<model>/<condition>)")
    ap.add_argument("--dev", action="store_true", help="dev meetings instead of test")
    ap.add_argument("--chunk-minutes", type=float, default=0, help="M08: notes per part, then a merge pass")
    ap.add_argument("--merge", default="m08", choices=["m08", "dedup"], help="M08b: merge prompt")
    ap.add_argument("--thorough", action="store_true", help="M08b: one pass asked for thorough notes")
    ap.add_argument("--server", help="M09: llama-server URL; MODEL is then only a name for the output folder")
    a = ap.parse_args()
    if a.dev and a.meetings == MEETINGS:
        a.meetings = DEV_MEETINGS
    out = Path(a.out) if a.out else BENCH / "m05" / a.model.split("/")[-1] / a.condition
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    if not a.server:
        model, tok = load(a.model)
        sampler = make_sampler(temp=0.0)
    load_s = time.time() - t0
    with open(out / "timings.jsonl", "w") as log:
        log.write(json.dumps({"event": "loaded", "model": a.model, "seconds": load_s}) + "\n")
        def generate(content, max_tokens):
            if a.server:
                body = {"messages": [{"role": "user", "content": content}], "max_tokens": max_tokens,
                        "temperature": 0, "seed": 0, "chat_template_kwargs": {"enable_thinking": False}}
                req = urllib.request.Request(a.server.rstrip("/") + "/v1/chat/completions", json.dumps(body).encode(),
                                             {"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=7200) as r:
                    res = json.loads(r.read())
                t = res["timings"]
                return res["choices"][0]["message"]["content"].strip(), SimpleNamespace(
                    prompt_tokens=t["prompt_n"], prompt_tps=t["prompt_per_second"],
                    generation_tokens=t["predicted_n"], generation_tps=t["predicted_per_second"])
            prompt = tok.apply_chat_template([{"role": "user", "content": content}], add_generation_prompt=True,
                                             enable_thinking=False)
            text, last = "", None
            for r in stream_generate(model, tok, prompt, max_tokens=max_tokens, sampler=sampler):
                text += r.text
                last = r
            return text.strip(), last

        for m in a.meetings:
            full = transcript(m, a.condition, a.dev)
            mx.reset_peak_memory()
            start = time.time()
            if a.chunk_minutes:
                parts = chunks(full, a.chunk_minutes)
                notes, steps = [], []
                for i, (s0, s1, part) in enumerate(parts, 1):
                    text, last = generate(CHUNK_PROMPT.format(i=i, n=len(parts), start=s0, end=s1, transcript=part), 800)
                    notes.append(f"# Part {i} of {len(parts)} (minutes {s0} to {s1})\n\n{text}")
                    steps.append((last.prompt_tokens, last.generation_tokens))
                (out / f"{m}.parts.md").write_text("\n\n".join(notes) + "\n")
                merge, budget = (DEDUP_PROMPT, 2000) if a.merge == "dedup" else (MERGE_PROMPT, 1200)
                text, last = generate(merge.format(n=len(parts), parts="\n\n".join(notes)), budget)
                extra = {"parts": len(parts), "part_tokens": steps}
            else:
                prompt = PROMPT.replace("\n\nTranscript:", THOROUGH + "\n\nTranscript:") if a.thorough else PROMPT
                text, last = generate(prompt.format(transcript=full), 2000 if a.thorough else 1200)
                extra = {}
            wall = time.time() - start
            (out / f"{m}.md").write_text(text + "\n")
            row = {"meeting": m, "prompt_tokens": last.prompt_tokens, "prefill_tps": last.prompt_tps,
                   "gen_tokens": last.generation_tokens, "gen_tps": last.generation_tps, "wall_s": wall,
                   "peak_gb": mx.get_peak_memory() / 1e9, **extra}
            log.write(json.dumps(row) + "\n")
            log.flush()
            print(json.dumps(row), flush=True)


if __name__ == "__main__":
    main()
