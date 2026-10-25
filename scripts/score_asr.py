"""Score Parakeet output against Kai's final text and Wispr's raw ASR. Writes data/asr_results.jsonl."""
import json, re, statistics, sys
import jiwer

FILLERS = re.compile(r"\b(um+|uh+|erm|hmm+|ah)\b")
def norm(s):
    s = jiwer.RemovePunctuation()(s.lower().replace("-", " "))
    return " ".join(FILLERS.sub(" ", s).split())

src = sys.argv[1] if len(sys.argv) > 1 else "data/asr_v2.jsonl"
ts = {json.loads(l)["transcriptEntityId"]: json.loads(l) for l in open("data/testset.jsonl")}
res = [json.loads(l) for l in open(src)]
by = {}
with open(src.replace(".jsonl", "_scored.jsonl"), "w") as f:
    for r in res:
        t = ts[r["id"]]
        final, wraw, ours = norm(t["finalText"]), norm(t["asrText"]), norm(r["text"])
        r["wer_vs_final"] = jiwer.wer(final, ours)
        r["wispr_wer_vs_final"] = jiwer.wer(final, wraw)
        r["wer_vs_wispr_asr"] = jiwer.wer(wraw, ours)
        by.setdefault(r["bucket"], []).append(r); by.setdefault("ALL", []).append(r)
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
# word-weighted WER over the set is fairer than a mean of per-clip WERs
def pooled(rs, hyp_key):
    refs = [norm(ts[r["id"]]["finalText"]) for r in rs]
    hyps = [norm(r["text"]) if hyp_key == "ours" else norm(ts[r["id"]]["asrText"]) for r in rs]
    return jiwer.wer(refs, hyps)
print("bucket  n   Parakeet WER vs your final   Wispr raw ASR WER vs your final   Parakeet vs Wispr raw")
for b in ["short", "med", "long", "xl", "ALL"]:
    rs = by.get(b, [])
    if rs:
        agree = jiwer.wer([norm(ts[r["id"]]["asrText"]) for r in rs], [norm(r["text"]) for r in rs])
        print(f"{b:6} {len(rs):2}   {pooled(rs,'ours'):26.3f}   {pooled(rs,'wispr'):31.3f}   {agree:20.3f}")
