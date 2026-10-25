"""Run recent real dictations from MurmurBee's history through every trained cleanup model, side by side.
Usage: python scripts/compare_recent.py <first_id> <last_id>  -> bench/compare_recent.md
Input per dictation: the raw transcript and the app's context (vocab + Kai's name, text before the cursor), fed whole
(the app feeds chunks), so this compares the models themselves. App-side post-edits are not applied here."""
import json, pathlib, re, sqlite3, sys, time
sys.path.insert(0, "scripts")
from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler
from prompt_v2 import SYSTEM, user_message

lo, hi = int(sys.argv[1]), int(sys.argv[2])
db = sqlite3.connect(pathlib.Path.home() / "Library/Application Support/MurmurBee/history.sqlite")
rows = db.execute("SELECT id, app_name, app_type, asr_text, cleaned_text, vocab, before_cursor FROM dictations "
                  "WHERE id BETWEEN ? AND ? ORDER BY id", (lo, hi)).fetchall()
MODELS = [
    ("v1 (E07)", "models/qwen35-0.8b-kai-v1", None, "v1"),
    ("v2 (E09 step 600)", "models/qwen35-0.8b-kai-v2", None, "v2"),
    ("E10 step 1200 (self-correction run)", "mlx-community/Qwen3.5-0.8B-4bit", "adapters/eval-resumed0001200", "v2"),
    ("v3 (E12 step 3000, installed)", "models/qwen35-0.8b-kai-v3", None, "v2"),
]
sampler = make_sampler(temp=0.0)
results = {r[0]: {} for r in rows}
for label, path, adapter, prompt in MODELS:
    model, tok = load(path, adapter_path=adapter)
    for rid, app, typ, raw, _, vocab, before in rows:
        v = [t for t in (vocab or "").split("; ") if t] + ["Kai Kaushik", "Kai"]
        v = list(dict.fromkeys(v))[:12]
        u = user_message(app, typ, raw, v, before or "") if prompt == "v2" else f"app={app} type={typ}\n<transcript>{raw}</transcript>"
        sys_prompt = SYSTEM
        p = tok.apply_chat_template([{"role": "system", "content": sys_prompt}, {"role": "user", "content": u}],
                                    tokenize=True, add_generation_prompt=True, enable_thinking=False)
        t, out = time.perf_counter(), ""
        for resp in stream_generate(model, tok, p, max_tokens=int(len(raw.split()) * 2.1) + 24, sampler=sampler):
            out += resp.text
        results[rid][label] = (out.strip(), (time.perf_counter() - t) * 1000)
    del model

md = ["# Recent dictations through every trained model", "",
      "Whole-dictation input (the app works in chunks), same context the app sends. No app post-edits applied.", ""]
for rid, app, typ, raw, app_out, vocab, _ in rows:
    md += [f"## #{rid} · {app} ({typ})", "", f"**Raw transcript:** {raw}", "", f"**What the app pasted:** {app_out!r}", ""]
    for label, *_ in MODELS:
        out, ms = results[rid][label]
        md += [f"**{label}** ({ms:.0f} ms):", "", "```", out, "```", ""]
pathlib.Path("bench/compare_recent.md").write_text("\n".join(md))
print("wrote bench/compare_recent.md")
