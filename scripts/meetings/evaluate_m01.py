"""M01 results: diarization (DER) and speaker-attributed transcripts (WER, cpWER) from one mixed channel.

Reads bench/meetings/m01/, writes bench/meetings/m01/results.json and prints a markdown table.
Speed is pooled: total audio / total compute over the 16 meetings (model loading excluded, reported separately).
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from score_der import score as der  # noqa: E402
from score_words import attribute, load_rttm, pooled, score as words_score, seglst  # noqa: E402

M01 = Path(__file__).resolve().parents[2] / "bench/meetings/m01"
ENGINES = ["offline", "sortformer", "lseend", "lseend-ami"]


def speed(log):
    rows = [json.loads(l) for l in log.read_text().splitlines() if l.startswith("{")]
    files = [r for r in rows if r["event"] == "file"]
    audio, compute = sum(r["audio_s"] for r in files), sum(r["compute_s"] for r in files)
    load = next(r["seconds"] for r in rows if r["event"] == "loaded")
    peak = next(r["peak_rss_mb"] for r in rows if r["event"] == "done")
    return {"audio_h": audio / 3600, "compute_s": compute, "rtfx": audio / compute, "load_s": load, "peak_mb": peak}


def main():
    results = {"asr": speed(M01 / "asr.log")}
    asr = {p.name.split(".")[0]: json.loads(p.read_text())["words"] for p in sorted((M01 / "asr").glob("*.json"))}
    # Words only (no speakers): one stream.
    results["asr"]["wer"] = pooled([words_score(m, seglst(m, [{**x, "spk": "all"} for x in w]))
                                    for m, w in asr.items()])["orc_wer"]
    for e in ENGINES:
        per_file, p = der(M01 / e)
        rows = [words_score(m, seglst(m, attribute(w, load_rttm(M01 / e / f"{m}.rttm")))) for m, w in asr.items()]
        results[e] = {"der": p, "der_per_file": per_file, "words": pooled(rows), "speed": speed(M01 / f"{e}.log")}
    (M01 / "results.json").write_text(json.dumps(results, indent=1))

    a = results["asr"]
    print(f"Transcription (Parakeet Ultra, mix): WER {a['wer']:.1%}, {a['rtfx']:.0f}x real time, "
          f"peak {a['peak_mb']:.0f} MB, {a['audio_h']:.2f} h of audio\n")
    print("| Diarizer | DER comparable | DER strict | DER full | miss | false alarm | confusion | right speaker count "
          "| cpWER | RTFx | peak MB |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for e in ENGINES:
        d, w, s = results[e]["der"], results[e]["words"], results[e]["speed"]
        print(f"| {e} | {d['comparable']:.1%} | {d['strict']:.1%} | {d['full']:.1%} | {d['miss']:.1%} | {d['fa']:.1%} "
              f"| {d['confusion']:.1%} | {d['correct_speaker_count']}/{d['files']} | {w['cpwer']:.1%} "
              f"| {s['rtfx']:.0f} | {s['peak_mb']:.0f} |")


if __name__ == "__main__":
    main()
