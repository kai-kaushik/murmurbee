"""Word-level scoring of a speaker-attributed transcript against AMI's manual transcripts.

A hypothesis is built from one or more channels:
  words JSON (meetbench transcribe) + who spoke: either an RTTM (each word gets the diarized speaker it overlaps
  most, or the nearest one) or a fixed label (the mic channel in a call is always "you").
Text on both sides goes through Whisper's English normaliser (fillers removed, numbers and spellings unified).

Metrics (meeteval):
  WER      words only: ORC-WER with the output collapsed into a single stream (all words in time order), so
           who-said-what is ignored. Exact ORC-WER over several output streams is exponential and runs out of
           memory on an AMI meeting.
  cpWER    words and speakers: best one-to-one mapping of output speakers to real speakers, then WER per speaker.
           Wrong words and words credited to the wrong person both count.
"""
import bisect
import glob
import json
from pathlib import Path

import meeteval
from transformers.models.whisper.english_normalizer import EnglishTextNormalizer

REFS = Path(__file__).resolve().parents[2] / "bench/meetings/refs"
_spelling = json.load(open(glob.glob(str(Path.home() / ".cache/huggingface/hub/models--openai--whisper-large-v3-turbo"
                                                  "/snapshots/*/normalizer.json"))[0]))
normalise = EnglishTextNormalizer(_spelling)


def load_rttm(path):
    segs = []
    for line in Path(path).read_text().splitlines():
        f = line.split()
        if len(f) >= 8 and f[0] == "SPEAKER":
            segs.append((float(f[3]), float(f[3]) + float(f[4]), f[7]))
    return sorted(segs)


def attribute(words, segs):
    """Speaker for each word: most overlap with a diarized segment, else the nearest segment."""
    starts = [s[0] for s in segs]
    out = []
    for w in words:
        best, best_ov = None, 0.0
        i = bisect.bisect_left(starts, w["e"])
        for s, e, spk in segs[max(0, i - 50):i]:
            ov = min(e, w["e"]) - max(s, w["s"])
            if ov > best_ov:
                best, best_ov = spk, ov
        if best is None and segs:
            mid = (w["s"] + w["e"]) / 2
            best = min(segs, key=lambda x: 0 if x[0] <= mid <= x[1] else min(abs(mid - x[0]), abs(mid - x[1])))[2]
        out.append({**w, "spk": best or "unknown"})
    return out


def seglst(meeting, words, gap=1.0):
    """Group each speaker's words into segments, splitting on pauses longer than `gap`."""
    segs = []
    for name in sorted({w["spk"] for w in words}):
        cur = None
        for w in sorted((w for w in words if w["spk"] == name), key=lambda w: w["s"]):
            if cur and w["s"] - cur["end_time"] <= gap:
                cur["words"] += " " + w["w"]
                cur["end_time"] = w["e"]
            else:
                cur = {"session_id": meeting, "speaker": name, "start_time": w["s"], "end_time": w["e"],
                       "words": w["w"]}
                segs.append(cur)
    return segs


def normalised(segs):
    out = [{**s, "words": normalise(s["words"])} for s in segs]
    return [s for s in out if s["words"].strip()]


def score(meeting, hyp_segs):
    ref = normalised(json.loads((REFS / f"{meeting}.seglst.json").read_text()))
    hyp = normalised(hyp_segs)
    ref_s, hyp_s = meeteval.io.SegLST(ref), meeteval.io.SegLST(hyp)
    one_stream = meeteval.io.SegLST([{**h, "speaker": "all"} for h in hyp])
    orc = meeteval.wer.api.orcwer(ref_s, one_stream)[meeting]
    cp = meeteval.wer.api.cpwer(ref_s, hyp_s)[meeting]
    return {"ref_words": orc.length, "orc_errors": orc.errors, "cp_errors": cp.errors,
            "orc_wer": orc.error_rate, "cpwer": cp.error_rate,
            "hyp_speakers": len({s["speaker"] for s in hyp}), "ref_speakers": len({s["speaker"] for s in ref})}


def pooled(rows):
    n = sum(r["ref_words"] for r in rows)
    return {"ref_words": n, "orc_wer": sum(r["orc_errors"] for r in rows) / n,
            "cpwer": sum(r["cp_errors"] for r in rows) / n}
