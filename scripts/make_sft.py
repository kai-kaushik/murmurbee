"""Build LoRA training data for the cleanup model from Kai's Wispr history.

Input  = Wispr's raw ASR text (with fillers, false starts), plus the app header the app will send.
Target = Kai's edited text when the edit is a correction (small change), otherwise Wispr's formatted text.
The 20 test clips are excluded. Writes data/sft/{train,valid}.jsonl in chat format.
"""
import json
import pathlib
import random

import jiwer

SYSTEM = "Clean up this dictated transcript. Output only the cleaned text."
APPS = {
    "com.anthropic.claudefordesktop": ("Claude", "AI assistant prompt"),
    "com.tinyspeck.slackmacgap": ("Slack", "work chat"),
    "com.apple.MobileSMS": ("Messages", "personal chat"),
    "net.whatsapp.WhatsApp": ("WhatsApp", "personal chat"),
    "com.apple.mail": ("Mail", "email"),
    "com.superhuman.electron": ("Superhuman", "email"),
    "com.google.Chrome": ("Chrome", "browser"),
    "com.microsoft.VSCode": ("VS Code", "code editor"),
    "com.todesktop.230313mzl4w4u92": ("Cursor", "code editor"),
}


def header(r):
    name, kind = APPS.get(r.get("app") or "", ((r.get("app") or "unknown").split(".")[-1], "general"))
    return f"app={name} type={kind}\n<transcript>{r['asrText'].strip()}</transcript>"


def norm(s):
    return " ".join(jiwer.RemovePunctuation()(s.lower()).split())


def target(r):
    fmt = (r.get("formattedText") or r.get("pastedText") or "").strip()
    ed = (r.get("editedText") or "").strip()
    if ed and fmt and norm(fmt) and jiwer.wer(norm(fmt), norm(ed)) <= 0.3:
        return ed, "edited"
    return fmt, "formatted"


test_ids = {json.loads(l)["transcriptEntityId"] for l in open("data/testset.jsonl")}
rows = []
for l in open("data/wispr-golden/text.jsonl"):
    r = json.loads(l)
    if r["transcriptEntityId"] in test_ids or not (r.get("asrText") or "").strip():
        continue
    if not (r.get("detectedLanguage") or r.get("language") or "en").startswith("en"):
        continue
    t, src = target(r)
    n = len(r["asrText"].split())
    if not t or n < 3 or n > 300:
        continue
    rows.append({"messages": [{"role": "system", "content": SYSTEM},
                              {"role": "user", "content": header(r)},
                              {"role": "assistant", "content": t}], "_src": src})

random.Random(7).shuffle(rows)
train, valid = rows[:3000], rows[3000:3200]
out = pathlib.Path("data/sft")
out.mkdir(exist_ok=True)
for name, part in [("train", train), ("valid", valid)]:
    with open(out / f"{name}.jsonl", "w") as f:
        for r in part:
            f.write(json.dumps({"messages": r["messages"]}, ensure_ascii=False) + "\n")
print(f"eligible {len(rows)}  train {len(train)} (edited targets: {sum(r['_src']=='edited' for r in train)})  valid {len(valid)}")
