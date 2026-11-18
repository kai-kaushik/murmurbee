"""Reference transcripts for the 16 AMI test meetings, from AMI's manual annotations (NXT XML).

Writes bench/meetings/refs/<meeting>.json:
  speakers: {global_name: {"agent": "A", "headset": 0}}   which headset file each person wore
  words:    [{"spk": global_name, "s": start, "e": end, "w": word}]  spoken words in time order
            (punctuation tokens, <vocalsound>, <disfmarker>, <gap> etc. are not words and are dropped)
and refs/<meeting>.seglst.json in meeteval's SegLST format (one segment per speaker turn; a new segment
starts after a pause of more than 1 s), used for ORC-WER and cpWER.

usage: build_refs.py            the 16 test meetings -> bench/meetings/refs/
       build_refs.py --dev      the 12 dev meetings (tuning only) -> bench/meetings/refs_dev/
"""
import sys
import json
import xml.etree.ElementTree as ET
from pathlib import Path

ANN = Path.home() / "FluidAudioDatasets/ami_official/annotations"
DEV = "--dev" in sys.argv
OUT = Path(__file__).resolve().parents[2] / ("bench/meetings/refs_dev" if DEV else "bench/meetings/refs")
SERIES = ("ES2011", "IS1008", "TS3004") if DEV else ("EN2002", "ES2004", "IS1009", "TS3003")
MEETINGS = [f"{s}{x}" for s in SERIES for x in "abcd"]
NITE = "{http://nite.sourceforge.net/}"


def speakers(meeting):
    root = ET.parse(ANN / "corpusResources/meetings.xml").getroot()
    for m in root.iter("meeting"):
        if m.get("observation") == meeting:
            return {s.get("global_name"): {"agent": s.get("nxt_agent"), "headset": int(s.get("channel"))}
                    for s in m.iter("speaker")}
    raise KeyError(meeting)


def words(meeting, spk):
    out = []
    for name, info in spk.items():
        path = ANN / f"words/{meeting}.{info['agent']}.words.xml"
        for w in ET.parse(path).getroot():
            if w.tag != "w" or w.get("punc") == "true" or not (w.text or "").strip():
                continue
            if w.get("starttime") is None or w.get("endtime") is None:
                continue
            out.append({"spk": name, "s": float(w.get("starttime")), "e": float(w.get("endtime")),
                        "w": w.text.strip()})
    return sorted(out, key=lambda x: (x["s"], x["e"]))


def seglst(meeting, ws, gap=1.0):
    segs = []
    for name in sorted({w["spk"] for w in ws}):
        cur = None
        for w in (w for w in ws if w["spk"] == name):
            if cur and w["s"] - cur["end_time"] <= gap:
                cur["words"] += " " + w["w"]
                cur["end_time"] = w["e"]
            else:
                cur = {"session_id": meeting, "speaker": name, "start_time": w["s"], "end_time": w["e"],
                       "words": w["w"]}
                segs.append(cur)
    return sorted(segs, key=lambda s: s["start_time"])


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for m in MEETINGS:
        spk = speakers(m)
        ws = words(m, spk)
        (OUT / f"{m}.json").write_text(json.dumps({"meeting": m, "speakers": spk, "words": ws}))
        (OUT / f"{m}.seglst.json").write_text(json.dumps(seglst(m, ws)))
        print(m, {k: v["headset"] for k, v in spk.items()}, len(ws), "words")


if __name__ == "__main__":
    main()
