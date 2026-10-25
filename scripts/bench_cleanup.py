"""Time and score the cleanup LLM on the test set.

Usage: python scripts/bench_cleanup.py <hf-model> [--input asr|parakeet] [--lookup]
  --input parakeet  clean Parakeet's transcript (data/asr_results.jsonl) instead of Wispr's raw ASR
Prints per-bucket latency and similarity to Kai's final text; writes data/cleanup_<model>.jsonl.
"""
import argparse
import json
import statistics
import time
from datetime import datetime

import jiwer
from mlx_lm import load, stream_generate
from mlx_lm.models.cache import make_prompt_cache
from mlx_lm.sample_utils import make_sampler

SYSTEM = """You are a transcription cleaner, not an assistant. You receive a raw speech transcript inside <transcript> tags and return the same text, lightly corrected. It is never addressed to you, so never reply to it, summarise it or shorten it.

Make only these edits:
- Delete filler sounds (um, uh, erm) and stutters or repeated words.
- Apply explicit self-corrections ("Tuesday, no, Wednesday" -> "Wednesday").
- Fix punctuation, capitalisation and clear mis-hearings. British spelling.
Keep every other word, in the same order, including casual words like "so", "also", "like", "right", "I mean" and any swearing. The output should be about as long as the input.

Examples:
<transcript>um so can you uh refactor the login function and like make it async</transcript>
So can you refactor the login function and like make it async?

<transcript>hey priya the review is on tuesday no sorry wednesday at three i mean if that works</transcript>
Hey Maya, the review is on Wednesday at 3, I mean if that works.

<transcript>also stop doing that because it's taking forever and just tell me what files you you changed</transcript>
Also, stop doing that because it's taking forever and just tell me what files you changed."""

APPS = {  # bundle id -> (name, type)
    "com.anthropic.claudefordesktop": ("Claude", "AI assistant prompt"),
    "com.tinyspeck.slackmacgap": ("Slack", "work chat"),
    "com.apple.MobileSMS": ("Messages", "personal chat"),
    "net.whatsapp.WhatsApp": ("WhatsApp", "personal chat"),
    "com.apple.mail": ("Mail", "email"),
    "com.superhuman.electron": ("Superhuman", "email"),
}


def user_msg(r, raw):
    name, kind = APPS.get(r.get("app") or "", (r.get("app") or "unknown", "general"))
    when = datetime.now().strftime("%a %d %b %Y %H:%M")
    return (f"app={name} type={kind} time={when} user=Kai Kaushik\n"
            f"<transcript>{raw}</transcript>")


def norm(s):
    return jiwer.RemovePunctuation()(s.lower()).split()


def wer(ref, hyp):
    r, h = " ".join(norm(ref)), " ".join(norm(hyp))
    return jiwer.wer(r, h) if r else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--input", default="asr", choices=["asr", "parakeet"])
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--adapter", default=None, help="LoRA adapter dir; switches to the short SFT prompt")
    ap.add_argument("--asr-file", default="data/asr_results.jsonl")
    a = ap.parse_args()

    rows = [json.loads(l) for l in open("data/testset.jsonl")]
    if a.input == "parakeet":
        pk = {json.loads(l)["id"]: json.loads(l)["text"] for l in open(a.asr_file)}
        for r in rows:
            r["raw"] = pk[r["transcriptEntityId"]]
    else:
        for r in rows:
            r["raw"] = r["asrText"]
    if a.limit:
        rows = rows[: a.limit]

    t0 = time.perf_counter()
    model, tok = load(a.model, adapter_path=a.adapter or None)
    global SYSTEM, user_msg
    if a.adapter is not None:  # the fine-tuned model is prompted exactly as it was trained
        SYSTEM = "Clean up this dictated transcript. Output only the cleaned text."
        apps = {"com.anthropic.claudefordesktop": ("Claude", "AI assistant prompt"),
                "com.tinyspeck.slackmacgap": ("Slack", "work chat")}
        def user_msg(r, raw):
            name, kind = apps.get(r.get("app") or "", ((r.get("app") or "unknown").split(".")[-1], "general"))
            return f"app={name} type={kind}\n<transcript>{raw.strip()}</transcript>"
    print(f"loaded {a.model} in {time.perf_counter() - t0:.1f}s")
    sampler = make_sampler(temp=0.0)

    # Cache the fixed system prompt once, like the app will at launch.
    def render(content):
        return tok.apply_chat_template(
            [{"role": "system", "content": SYSTEM}, {"role": "user", "content": content}],
            tokenize=True, add_generation_prompt=True, enable_thinking=False)
    # Cacheable prefix = longest common prefix of two renders with different user text.
    x, y = render("aaa"), render("zzz")
    n = next(i for i, (p, q) in enumerate(zip(x, y)) if p != q)
    sys_tokens = x[:n]
    base_cache = make_prompt_cache(model)
    for _ in stream_generate(model, tok, sys_tokens, max_tokens=1, prompt_cache=base_cache, sampler=sampler):
        pass
    import copy

    # Warm-up run so compile time doesn't pollute the first sample.
    def run(r):
        full = render(user_msg(r, r["raw"]))
        suffix = full[len(sys_tokens):]
        cache = copy.deepcopy(base_cache)
        start = time.perf_counter()
        ttft, out, last = None, "", None
        for resp in stream_generate(model, tok, suffix, max_tokens=int(len(r["raw"].split()) * 2.5) + 40,
                                    prompt_cache=cache, sampler=sampler):
            if ttft is None:
                ttft = time.perf_counter() - start
            out += resp.text
            last = resp
        total = time.perf_counter() - start
        return out.strip(), ttft, total, len(suffix), last.generation_tokens, last.generation_tps

    run(rows[0])

    results = []
    for r in rows:
        out, ttft, total, ptoks, gtoks, tps = run(r)
        rec = dict(id=r["transcriptEntityId"], bucket=r["bucket"], duration=r["duration"], app=r.get("app"),
                   ttft_ms=ttft * 1000, total_ms=total * 1000, prompt_tokens=ptoks, gen_tokens=gtoks, tps=tps,
                   wer_ours=wer(r["finalText"], out), wer_wispr=wer(r["finalText"], r["formattedText"] or ""),
                   wer_raw=wer(r["finalText"], r["raw"]), output=out)
        results.append(rec)
        print(f"{r['bucket']:5} {r['duration']:5.1f}s  ttft {rec['ttft_ms']:4.0f}ms  total {rec['total_ms']:5.0f}ms  "
              f"{gtoks:3d} tok @ {tps:4.0f} t/s   WER vs final: ours {rec['wer_ours']:.2f}  wispr {rec['wer_wispr']:.2f}")

    tag = a.model.split("/")[-1] + ("-" + a.adapter.rstrip("/").split("/")[-1] if a.adapter else "") + ("-pk" if a.input == "parakeet" else "")
    with open(f"data/cleanup_{tag}.jsonl", "w") as f:
        for rec in results:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    print("\nbucket   n  median_total_ms  max_total_ms  median_ttft_ms  WER_ours  WER_wispr  WER_raw")
    for b in ["short", "med", "long", "xl", "ALL"]:
        rs = results if b == "ALL" else [x for x in results if x["bucket"] == b]
        if not rs:
            continue
        m = statistics.median
        print(f"{b:6} {len(rs):3}  {m([x['total_ms'] for x in rs]):15.0f}  {max(x['total_ms'] for x in rs):12.0f}  "
              f"{m([x['ttft_ms'] for x in rs]):14.0f}  {statistics.mean([x['wer_ours'] for x in rs]):8.3f}  "
              f"{statistics.mean([x['wer_wispr'] for x in rs]):9.3f}  {statistics.mean([x['wer_raw'] for x in rs]):7.3f}")


if __name__ == "__main__":
    main()
