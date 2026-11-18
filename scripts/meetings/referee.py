"""M05 referee: scores generated meeting notes. The referee models never write the summaries being judged.

Two checks, one question per item, one-word answers, greedy decoding:
  coverage      for every item of AMI's human summary (abstract sentences, decisions, actions, problems):
                do the generated notes cover it? yes / partly / no. Speaker names and roles are ignored (the
                generated notes only know "Speaker N", AMI's summaries say "the Project Manager").
  faithfulness  for every bullet and summary sentence in the generated notes: is it supported by the meeting's
                manual transcript? supported / unsupported (contradicted, or a detail that was not said).
Scores: coverage = (yes + 0.5 * partly) / items; unsupported = unsupported claims / claims.

One question at a time because asking for a JSON list of verdicts failed: on a 10k-token transcript the referee
answered the first few statements and then marked every later one unsupported, including ones it plainly says
(checked by hand on ES2004a). The transcript is prefilled once per meeting and its KV cache copied for each
statement, so per-statement questions cost only the statement's own tokens.

usage: referee.py REFEREE_MODEL [--dev] [--coverage-only] NOTES_DIR [NOTES_DIR ...]
writes <NOTES_DIR>/referee-<model>.json. --coverage-only skips faithfulness (M05 found its flags unreliable).
"""
import copy
import json
import re
import sys
from pathlib import Path

import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache

sys.path.insert(0, str(Path(__file__).parent))
from summarise import BENCH, DEV_MEETINGS, MEETINGS, label_speakers, render  # noqa: E402

ABS = Path.home() / "FluidAudioDatasets/ami_official/annotations/abstractive"
SECTIONS = ("abstract", "decisions", "actions", "problems")
SLOT = "\x00SLOT\x00"

COVERAGE = """You are checking meeting notes against one point from a reference summary written by a person who \
watched the meeting. Wording, speaker names and job titles do not matter (the notes call people "Speaker 1" and so \
on); only whether the point itself is in the notes.

Meeting notes:
{notes}

Reference point: """ + SLOT + """

Do the notes cover this point? Answer with one word: yes (clearly there), partly (only part of it) or no (missing)."""

FAITHFUL = """You are checking a statement from notes about a meeting against the meeting's full transcript. \
"supported" means it was said or clearly follows from what was said. "unsupported" means it contradicts the \
transcript, or adds a detail (a name, number, date, decision or owner) that was not said. Speaker labels may differ; \
judge the content.

Transcript:
{transcript}

Statement: """ + SLOT + """

Is the statement supported by the transcript? Answer with one word: supported or unsupported."""

VERDICTS = {"coverage": ("partly", "yes", "no"), "faithful": ("unsupported", "supported")}


def reference_items(meeting):
    xml = (ABS / f"{meeting}.abssumm.xml").read_text(encoding="latin-1")
    items = []
    for sec in SECTIONS:
        block = re.search(rf"<{sec}[^>]*>(.*?)</{sec}>", xml, re.S)
        for s in re.findall(r"<sentence[^>]*>(.*?)</sentence>", block.group(1) if block else "", re.S):
            text = " ".join(s.split())
            if text.rstrip(".").upper() != "NA":  # AMI writes "NA." for an empty section
                items.append((sec, text))
    return items


def claims(notes):
    """Bullets, plus the sentences of the Summary paragraph. 'None' bullets are not claims."""
    out, section = [], None
    for line in notes.splitlines():
        line = line.strip()
        if line.startswith("#"):
            section = line.lstrip("#").strip().lower()
            continue
        if not line:
            continue
        text = re.sub(r"^[*\-•]\s*|\*\*", "", line).strip()
        if not text or text.lower().rstrip(".") == "none":
            continue
        if section and section.startswith("summary") and not re.match(r"^[*\-•]", line):
            out += [s for s in re.split(r"(?<=[.!?])\s+", text) if len(s) > 3]
        else:
            out.append(text)
    return out


class Referee:
    def __init__(self, model_id):
        self.model, self.tok = load(model_id)

    def _tokens(self, text):
        return self.tok.encode(text, add_special_tokens=False)  # the chat template already holds BOS

    def _forward(self, tokens, cache, step=2048):
        for i in range(0, len(tokens), step):
            logits = self.model(mx.array(tokens[i:i + step])[None], cache=cache)
            mx.eval(logits)
        return logits[0, -1]

    def prepare(self, prompt):
        """Prefill everything before the slot once; returns (cache, text after the slot)."""
        text = self.tok.apply_chat_template([{"role": "user", "content": prompt}], add_generation_prompt=True,
                                            enable_thinking=False, tokenize=False)
        head, tail = text.split(SLOT)
        cache = make_prompt_cache(self.model)
        self._forward(self._tokens(head), cache)
        return cache, tail

    def ask(self, prepared, item, kind, max_tokens=4):
        cache, tail = copy.deepcopy(prepared[0]), prepared[1]
        logits, out = self._forward(self._tokens(item + tail), cache), []
        for _ in range(max_tokens):
            t = int(logits.argmax())
            if t in self.tok.eos_token_ids:
                break
            out.append(t)
            logits = self._forward([t], cache)
        answer = self.tok.decode(out).strip().lower()
        return next((v for v in VERDICTS[kind] if answer.startswith(v)), "unparsed:" + answer)


def main():
    flags = {a for a in sys.argv[2:] if a.startswith("--")}
    model_id, dirs = sys.argv[1], [Path(d) for d in sys.argv[2:] if not d.startswith("--")]
    meetings, refs = (DEV_MEETINGS, "refs_dev") if "--dev" in flags else (MEETINGS, "refs")
    coverage_only = "--coverage-only" in flags
    # Freed KV-cache copies otherwise stay in MLX's buffer cache; with a 19 GB model on a 32 GB Mac that swaps.
    mx.set_cache_limit(1 << 30)
    ref = Referee(model_id)
    out = {d: d / f"referee-{model_id.split('/')[-1]}.json" for d in dirs}
    rows = {d: json.loads(out[d].read_text()) if out[d].exists() else {} for d in dirs}  # resume
    for meeting in meetings:
        if all(meeting in rows[d] for d in dirs):
            continue
        if not coverage_only:
            gold = render(label_speakers(json.loads((BENCH / f"{refs}/{meeting}.json").read_text())["words"]))
            transcript = ref.prepare(FAITHFUL.format(transcript=gold))
        items = reference_items(meeting)
        for d in dirs:
            if meeting in rows[d]:
                continue
            notes = (d / f"{meeting}.md").read_text()
            prepared = ref.prepare(COVERAGE.format(notes=notes))
            cov = [ref.ask(prepared, t, "coverage") for _, t in items]
            cl = [] if coverage_only else claims(notes)
            fai = [ref.ask(transcript, c, "faithful") for c in cl]
            rows[d][meeting] = {"items": [{"section": s, "text": t, "verdict": v} for (s, t), v in zip(items, cov)],
                                "claims": [{"text": c, "verdict": v} for c, v in zip(cl, fai)]}
            print(meeting, d.parent.name, d.name, cov.count("yes"), "+", cov.count("partly"), "/", len(items),
                  "covered;", fai.count("unsupported"), "/", len(cl), "unsupported", flush=True)
            out[d].write_text(json.dumps(rows[d], indent=1))


if __name__ == "__main__":
    main()
