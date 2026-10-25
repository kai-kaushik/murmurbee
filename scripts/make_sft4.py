"""Training data v4 (E13): prompt v3 with full context (user, locale, time zone, local time, URL, selected text,
text before and after the cursor) plus four data fixes found in real use:
  G  self-corrections followed by more speech (the model had learned that a correction ends the dictation)
  H  misheard names in the transcript with the right name in the hints ("Samm" + vocab Sam -> Sam)
  I  misheard sign-off names in email ("Regards. Hi", "regard Sky" -> "Regards,\nKai")
  J  spoken times ("8 30", "10 30 am" -> "8:30", "10:30 am")
Same locked splits as v3; anything recorded on/after the test cut-off is never trained on.

Based on: Training data v3 (E12+): the v2 recipe on locked splits (data/splits.json, see scripts/make_splits.py).

  MODE=train (default): training data. Excludes every dev/test clip, their near-duplicates, and any sentence
                        whose hash puts it in the dev/test sentence pools. Writes OUT/train.jsonl + valid.jsonl
                        (valid = hash slice of the training data, for the loss curve only).
  MODE=dev | MODE=test: behaviour suites built from that split's held-out sentence pool and clips.
                        Writes OUT/<mode>_suites.jsonl.
Other changes from v2: real self-corrections (E) are kept only when the rest of the sentence survives intact.

Original v2 notes:
Training data v2 for the cleanup model.

Four kinds of examples, all in prompt format v2 (scripts/prompt_v2.py):
  A. Real dictations. Input is Parakeet's transcript where we have audio (real ASR errors), else Wispr's raw ASR.
     Context comes from what Wispr captured: on-screen names, dictionary, text before the cursor.
  B. Continuations: real dictations split at a sentence or mid-sentence, with the already-written part as <before>.
     This is what the app sends for the 2nd+ chunk of a dictation.
  C. Structure, built from Kai's own sentences: spoken lists, emails with greeting/sign-off, "quote ... unquote".
  D. Continuations of C split at list items and before sign-offs.
Fillers are left to the model (no rule-based removal). Test-set dictations are excluded.
"""
import json
import random
import re
from difflib import SequenceMatcher

import jiwer

from prompt_v3 import SYSTEM, clean_url, join, tz_label, user_message
from datetime import datetime, timedelta

import hashlib
import os
rng = random.Random(11)
MODE = os.environ.get("MODE", "train")
OUT = os.environ.get("OUT", "data/sft4")
SPLITS = json.load(open("data/splits.json"))
SPLIT_IDS = {"dev": set(SPLITS["dev"]), "test": set(SPLITS["test"])}
HELD = SPLIT_IDS["dev"] | SPLIT_IDS["test"] | set(SPLITS["near_duplicates_removed"])


def sentence_pool(target):
    h = int(hashlib.sha1(target.encode()).hexdigest(), 16) % 40
    return "dev" if h < 3 else "test" if h < 6 else "train"


SCALE = 1.0 if MODE == "train" else 0.06  # suites are small
APPS = {
    "com.anthropic.claudefordesktop": ("Claude", "AI assistant prompt"),
    "com.openai.chat": ("ChatGPT", "AI assistant prompt"),
    "com.tinyspeck.slackmacgap": ("Slack", "work chat"),
    "com.apple.MobileSMS": ("Messages", "personal chat"),
    "net.whatsapp.WhatsApp": ("WhatsApp", "personal chat"),
    "com.apple.mail": ("Mail", "email"),
    "com.superhuman.electron": ("Superhuman", "email"),
    "com.google.Chrome": ("Chrome", "browser"),
    "com.microsoft.VSCode": ("VS Code", "code editor"),
    "com.todesktop.230313mzl4w4u92": ("Cursor", "code editor"),
}
EMAIL_APPS = [("Gmail", "email"), ("Mail", "email"), ("Superhuman", "email")]


def app_of(r):
    a = r.get("app") or ""
    if "mail.google.com" in (r.get("url") or ""):
        return ("Gmail", "email")
    return APPS.get(a, (a.split(".")[-1] if a else "unknown", "general"))


def norm_words(s):
    return [jiwer.RemovePunctuation()(w.lower()) for w in s.split()]


def target_of(r):
    fmt = (r.get("formattedText") or r.get("pastedText") or "").strip()
    ed = (r.get("editedText") or "").strip()
    if ed and fmt:
        a, b = " ".join(norm_words(fmt)), " ".join(norm_words(ed))
        if a and jiwer.wer(a, b) <= 0.3:
            return ed
    return fmt


def vocab_for(r, target):
    """Terms from Wispr's context that the target actually uses, plus a few distractors (like the app sends)."""
    pool = []
    for k in ("axContext", "dictionaryContext"):
        try:
            pool += json.loads(r.get(k) or "[]")
        except Exception:
            pass
    pool = [t for t in dict.fromkeys(pool) if isinstance(t, str) and 2 < len(t) < 30 and "@" not in t]
    low = target.lower()
    used = [t for t in pool if re.search(r"\b" + re.escape(t.lower()) + r"\b", low)]
    rest = [t for t in pool if t not in used]
    vocab = used[:8] + rng.sample(rest, min(len(rest), rng.randint(0, 4)))
    rng.shuffle(vocab)
    return vocab


USER = "Kai Kaushik"
TZS = ["UTC+01:00", "UTC+00:00", "UTC-07:00", "UTC-04:00", "UTC+05:30"]


def keep(p=0.85):
    return rng.random() < p


def fmt_time(dt):
    return dt.strftime("%a %d %b %Y %H:%M")


def ctx_for(r):
    """Context from what Wispr recorded with this dictation (each field dropped sometimes, so the model copes
    when the app can't read one)."""
    c = {}
    if keep(0.9):
        c["user"] = (r.get("userName") or USER).strip()
    if keep(0.9):
        c["locale"] = "en-GB"
    off = r.get("timezoneOffsetMinutes")
    if off is not None and keep(0.9):
        c["tz"] = tz_label(off)
        try:
            utc = datetime.fromisoformat(r["timestamp"].replace(" +00:00", "+00:00").replace(" ", "T"))
            c["time"] = fmt_time(utc - timedelta(minutes=int(off)))
        except Exception:
            pass
    u = clean_url(r.get("url"))
    if u:
        c["url"] = u
    if r.get("selectedText"):
        c["selected"] = r["selectedText"]
    if r.get("afterText") and keep(0.8):
        c["after"] = r["afterText"]
    return c


def random_ctx(app):
    c = {}
    if keep(0.9):
        c["user"] = USER
    if keep(0.9):
        c["locale"] = "en-GB"
    if keep(0.85):
        c["tz"] = rng.choice(TZS)
        c["time"] = fmt_time(datetime(2026, rng.randint(1, 10), rng.randint(1, 28), rng.randint(7, 23), rng.randint(0, 59)))
    if app[0] == "Gmail" and keep(0.5):
        c["url"] = "mail.google.com/mail"
    return c


def example(app, raw, target, vocab=(), before="", ctx=None):
    ctx = random_ctx(app) if ctx is None else ctx
    return {"messages": [{"role": "system", "content": SYSTEM},
                         {"role": "user", "content": user_message(app[0], app[1], raw, vocab, before, **ctx)},
                         {"role": "assistant", "content": target.strip()}]}


def split_continuation(raw, target, mid_sentence):
    """Split a (raw, target) pair at the same point in both, using a word alignment."""
    rw, tw = raw.split(), list(re.finditer(r"\S+", target))
    rn, tn = norm_words(raw), [jiwer.RemovePunctuation()(m.group().lower()) for m in tw]
    if len(rw) < 12 or len(tw) < 12:
        return None
    blocks = [b for b in SequenceMatcher(None, rn, tn, autojunk=False).get_matching_blocks() if b.size >= 3]
    if mid_sentence:
        cands = [(b.a + k, b.b + k) for b in blocks for k in range(1, b.size - 1)]
    else:  # target word that starts a sentence
        cands = [(b.a + k, b.b + k) for b in blocks for k in range(b.size)
                 if b.b + k > 0 and re.search(r"[.?!]$", tw[b.b + k - 1].group())]
    cands = [(i, j) for i, j in cands if 4 <= i <= len(rw) - 4]
    if not cands:
        return None
    i, j = rng.choice(cands)
    cut = tw[j].start()
    return " ".join(rw[i:]), target[:cut].rstrip(), target[cut:].strip()


pk = {}
for f in ("data/asr_ultra_all.jsonl", "data/asr_ultra.jsonl"):
    try:
        pk.update({json.loads(l)["id"]: json.loads(l)["text"] for l in open(f)})
    except FileNotFoundError:
        pass

rows = []
for l in open("data/wispr-golden/text.jsonl"):
    r = json.loads(l)
    rid = r["transcriptEntityId"]
    if not (r.get("asrText") or "").strip():
        continue
    if MODE == "train" and (rid in HELD or r["timestamp"][:10] >= SPLITS["test_from"]):
        continue
    if MODE != "train" and rid in HELD and rid not in SPLIT_IDS[MODE]:
        continue
    if not (r.get("detectedLanguage") or r.get("language") or "en").startswith("en"):
        continue
    t = target_of(r)
    n = len(r["asrText"].split())
    if t and 3 <= n <= 300:
        r["_target"] = t
        r["_raw"] = pk.get(r["transcriptEntityId"]) or r["asrText"]
        r["_pk"] = r["transcriptEntityId"] in pk
        short_ok = 4 <= len(t.split()) <= 14 and t.count(".") + t.count("?") <= 1 and "\n" not in t
        r["_pool"] = sentence_pool(t) if short_ok else "train"
        if MODE == "train" and r["_pool"] != "train":
            continue  # its sentence belongs to a held-out suite pool
        rows.append(r)
rng.shuffle(rows)
# Real dictations in suite mode come only from that split's clips; sentence pools from that split's hash slice.
clip_rows = [r for r in rows if MODE == "train" or r["transcriptEntityId"] in SPLIT_IDS[MODE]]

out = {"A": [], "B": [], "C": [], "D": []}

# A. real dictations: all Parakeet-backed rows twice (real ASR errors matter most), plus Wispr-ASR rows.
pk_rows = [r for r in rows if r["_pk"]]
wispr_rows = [r for r in rows if not r["_pk"]][:3000]
for r in (pk_rows * 2 + wispr_rows if MODE == "train" else []):  # suite mode: clips are scored separately
    before = (r.get("beforeText") or "") if rng.random() < 0.8 else ""
    out["A"].append(example(app_of(r), r["_raw"], r["_target"], vocab_for(r, r["_target"]), before, ctx_for(r)))

# B. continuations of real dictations.
for r in (rows[:4000] if MODE == "train" else clip_rows):
    if len(out["B"]) >= int(1600 * SCALE) + (40 if MODE != "train" else 0):
        break
    s = split_continuation(r["_raw"], r["_target"], mid_sentence=rng.random() < 0.5)
    if s:
        raw_piece, written, piece = s
        c = ctx_for(r); c.pop("after", None)
        out["B"].append(example(app_of(r), raw_piece, piece, vocab_for(r, piece), written, c))

# C/D. structure from Kai's own short sentences.
short = [r for r in rows if 4 <= len(r["_target"].split()) <= 14 and r["_target"].count(".") + r["_target"].count("?") <= 1
         and "\n" not in r["_target"] and r["_pool"] == MODE]
names = ["Maya", "James", "Sarah", "Ava", "Tom", "Rich", "Jon", "Anna", "Mark", "Lisa", "team", "all"]
LIST_CUES = [("point one", "point two", "point three", "point four"),
             ("first", "second", "third", "fourth"),
             ("number one", "number two", "number three", "number four"),
             ("firstly", "secondly", "thirdly", "fourthly")]
BULLET_CUES = [("bullet point", "next bullet point", "next bullet point", "next bullet point"),
               ("bullet", "bullet", "bullet", "bullet")]
INTROS = [("so a few things", "So a few things:"), ("three things", "Three things:"),
          ("here's the plan", "Here's the plan:"), ("quick update", "Quick update:"),
          ("a couple of points", "A couple of points:"), ("", "")]
OUTROS = [("let me know what you think", "Let me know what you think."), ("thanks", "Thanks."), ("", "")]
SIGNOFFS = [("regards kai", "Regards,\nKai"), ("best regards kai", "Best regards,\nKai"),
            ("kind regards kai kaushik", "Kind regards,\nKai Kaushik"), ("thanks kai", "Thanks,\nKai"),
            ("cheers kai", "Cheers,\nKai"), ("best kai", "Best,\nKai"), ("many thanks kai", "Many thanks,\nKai")]


def spoken(r):
    """Raw-ish version of a sentence: the real ASR text, sometimes lowercased with punctuation dropped."""
    s = r["_raw"].strip()
    if rng.random() < 0.4:
        s = re.sub(r"[.,?!]", "", s[0].lower() + s[1:])
    return s


def sep():
    return rng.choice([", ", ". ", " "])


def lead(s):
    return s[0].upper() + s[1:] if s else s


for _ in range(int(700 * SCALE) + (10 if MODE != 'train' else 0)):
    app = rng.choice([("Slack", "work chat"), ("Notion", "general"), ("Claude", "AI assistant prompt"),
                      ("Gmail", "email"), ("Chrome", "browser")])
    n = rng.randint(2, 4)
    items = rng.sample(short, n)
    bullets = rng.random() < 0.3
    cues = rng.choice(BULLET_CUES if bullets else LIST_CUES)
    intro, outro = rng.choice(INTROS), rng.choice(OUTROS)
    raw_parts, tgt_lines = [], []
    if intro[0]:
        raw_parts.append(intro[0] + rng.choice([". ", ", ", " "]))
    for k, r in enumerate(items):
        filler = rng.choice(["", "", "um ", "uh "])
        raw_parts.append(f"{filler}{cues[k]}{sep()}{spoken(r)}{sep()}")
        tgt_lines.append(("- " if bullets else f"{k + 1}. ") + lead(r["_target"]))
    if outro[0]:
        raw_parts.append(outro[0])
    raw = "".join(raw_parts).strip()
    target = (intro[1] + "\n" if intro[1] else "") + "\n".join(tgt_lines) + ("\n\n" + outro[1] if outro[1] else "")
    out["C"].append(example(app, raw, target))
    # D: continue from item k (the app's next chunk starts at a list cue)
    k = rng.randint(1, n - 1)
    written = (intro[1] + "\n" if intro[1] else "") + "\n".join(tgt_lines[:k])
    piece = "\n".join(tgt_lines[k:]) + ("\n\n" + outro[1] if outro[1] else "")
    raw_piece = "".join(raw_parts[(1 if intro[0] else 0) + k:]).strip()
    assert join(written, piece, app[1]).startswith(written)
    out["D"].append(example(app, raw_piece, piece, before=written))

for _ in range(int(500 * SCALE) + (10 if MODE != 'train' else 0)):  # emails
    app = rng.choice(EMAIL_APPS)
    body = rng.sample(short, rng.randint(1, 3))
    name = rng.choice(names)
    greet = rng.choice([(f"hi {name.lower()}", f"Hi {name},"), (f"hey {name.lower()}", f"Hey {name},"),
                        (f"hello {name.lower()}", f"Hello {name},"), (f"dear {name.lower()}", f"Dear {name},"),
                        ("", "")])
    so = rng.choice(SIGNOFFS)
    raw = " ".join(x for x in [greet[0], " ".join(spoken(r) for r in body), so[0]] if x)
    body_t = " ".join(lead(r["_target"]) for r in body)
    target = (greet[1] + "\n\n" if greet[1] else "") + body_t + "\n\n" + so[1]
    out["C"].append(example(app, raw, target, vocab=["Kai Kaushik"]))
    # D: the sign-off arrives as its own chunk
    out["D"].append(example(app, so[0] + rng.choice(["", "."]), so[1],
                            before=(greet[1] + "\n\n" if greet[1] else "") + body_t))

for _ in range(int(250 * SCALE) + (10 if MODE != 'train' else 0)):  # quotes
    r = rng.choice(short)
    words = r["_target"].rstrip(".?!").split()
    if len(words) < 5:
        continue
    i = rng.randint(1, len(words) - 3)
    w = rng.randint(1, 3)
    if words[i + w - 1].lower().strip(",") in {"and", "the", "of", "to", "a", "an", "in", "on", "or", "for", "with", "is"}:
        continue
    phrase = " ".join(words[i:i + w])
    pre, post = " ".join(words[:i]), " ".join(words[i + w:])
    style = rng.choice(["qu", "qe", "aiq"])
    if style == "qu":
        raw = f"{pre} quote unquote {phrase} {post}".lower()
    elif style == "qe":
        raw = f"{pre} quote {phrase} end quote {post}".lower()
    else:
        raw = f"{pre} and I quote {phrase} unquote {post}".lower()
    target = lead(f'{pre} "{phrase}" {post}'.strip()) + r["_target"][-1:] if r["_target"][-1:] in ".?!" else ""
    if target:
        out["C"].append(example(("Slack", "work chat"), raw.strip(), target))

# E. Real self-corrections Wispr applied ("I mean …", "no wait …"): weighted up, they're the signature behaviour.
CUE = re.compile(r"\b(no wait|wait no|sorry,? (i mean|correct that)|correct that|scratch that|or rather|"
                 r"let me rephrase|no,? actually|i mean)\b", re.I)
out["E"] = []
def correction_is_local(raw, target):
    """Wispr often rewrote the whole sentence around an 'I mean'. Keep a correction only if nearly every target
    word was actually said and the target keeps most of the length (only the taken-back part is dropped)."""
    rw = set(norm_words(raw))
    tw = norm_words(target)
    if not tw:
        return False
    kept = sum(1 for w in tw if w in rw) / len(tw)
    return kept >= 0.92 and 0.6 <= len(tw) / max(len(norm_words(raw)), 1) <= 1.0


for r in (rows if MODE == "train" else clip_rows):
    if CUE.search(r["asrText"]) and not CUE.search(r["_target"]) and correction_is_local(r["_raw"], r["_target"]):
        out["E"].append(example(app_of(r), r["_raw"], r["_target"], vocab_for(r, r["_target"]),
                                (r.get("beforeText") or "") if rng.random() < 0.5 else "", ctx_for(r)))

# F. Explicit self-corrections built from Kai's own sentences: say a value, take it back, say the right one.
SLOTS = {
    "day": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
    "time": ["9", "10", "11", "noon", "2", "3", "4", "5", "half past 3", "quarter to 5"],
    "name": names[:-2] + ["Kai", "Mira", "Northwind", "Lumen"],
    "number": ["two", "three", "five", "ten", "twenty", "fifty", "a hundred"],
    "place": ["London", "Mumbai", "Tokyo", "Paris", "the office", "the cafe downstairs"],
}
TEMPLATES = [
    ("let's meet on {day}", "Let's meet on {day}"), ("can we move the review to {day}", "Can we move the review to {day}?"),
    ("i'm testing this on {day}", "I'm testing this on {day}"), ("the call is at {time}", "The call is at {time}"),
    ("send it to {name}", "Send it to {name}"), ("can you loop in {name}", "Can you loop in {name}?"),
    ("we need {number} more slides", "We need {number} more slides"), ("book a table for {number}", "Book a table for {number}"),
    ("i'll be in {place} next month", "I'll be in {place} next month"), ("ship it by {day}", "Ship it by {day}"),
    ("ask {name} to review the deck", "Ask {name} to review the deck"), ("we're landing at {time}", "We're landing at {time}"),
]
CORRECTION_CUES = ["no wait", "sorry", "sorry I mean", "I mean", "actually", "no actually", "sorry correct that",
                   "correct that", "wait no", "or rather", "no no", "sorry scratch that"]
out["F"] = []
for _ in range(int(900 * SCALE) + (10 if MODE != 'train' else 0)):
    tmpl_raw, tmpl_t = rng.choice(TEMPLATES)
    slot = re.search(r"\{(\w+)\}", tmpl_raw).group(1)
    wrong, right = rng.sample(SLOTS[slot], 2)
    cue = rng.choice(CORRECTION_CUES)
    end = "." if not tmpl_t.endswith("?") else ""
    if rng.random() < 0.7:  # "…on Tuesday, sorry, Wednesday"
        raw_core = tmpl_raw.format(**{slot: wrong}) + rng.choice([" ", ", ", ". "]) + cue + rng.choice([" ", ", "]) + right
    else:  # restart the whole phrase: "…on Tuesday. Sorry, correct that, let's meet on Wednesday"
        raw_core = (tmpl_raw.format(**{slot: wrong}) + rng.choice([". ", ", "]) + cue + rng.choice([" ", ", "])
                    + tmpl_raw.format(**{slot: right}))
    target_core = tmpl_t.format(**{slot: right})
    target_core = target_core[0].upper() + target_core[1:] + end
    # Wrap in a real sentence of Kai's half the time, before or after.
    ctx = rng.choice(short) if rng.random() < 0.85 else None
    filler = rng.choice(["", "", "um ", "uh "])
    if ctx and rng.random() < 0.25:  # (G) most corrections are now followed by more speech
        raw, target = f"{spoken(ctx)} {filler}{raw_core}", f"{lead(ctx['_target'])} {target_core}"
    elif ctx:
        raw, target = f"{filler}{raw_core}. {spoken(ctx)}", f"{target_core} {lead(ctx['_target'])}"
    else:
        raw, target = filler + raw_core, target_core
    app = rng.choice([("Slack", "work chat"), ("Gmail", "email"), ("Claude", "AI assistant prompt"),
                      ("Notion", "general"), ("Messages", "personal chat")])
    # Some arrive as a merged pair after a pause, with earlier text as <before> (what the app sends).
    before = lead(rng.choice(short)["_target"]) if rng.random() < 0.3 else ""
    out["F"].append(example(app, raw, target, before=before))

# H. Misheard names: corrupt a name the hints contain; the target keeps it spelled right.
def misspell(name):
    w = name
    swaps = [("k", "c"), ("c", "k"), ("v", "w"), ("i", "ee"), ("a", "e"), ("ph", "f"), ("sh", "s"), ("y", "i"),
             ("o", "u"), ("th", "t")]
    for _ in range(3):
        a, b = rng.choice(swaps)
        if a in w.lower():
            i = w.lower().index(a)
            w = w[:i] + (b if w[i].islower() else b.capitalize()) + w[i + len(a):]
            break
    if w == name or rng.random() < 0.3:
        i = rng.randint(1, max(1, len(w) - 2))
        w = w[:i] + (w[i] + w[i] if rng.random() < 0.5 else "") + w[i + 1:]
    return w if w != name else name + "s"


out["H"] = []
NAMES = ["Sam", "Maya", "Ava", "Brightwell", "Jon", "Leo", "Sid", "Ravi", "Anna", "Mira", "Northwind", "Lumen",
         "Rosa", "Tandem", "Mosaic", "Vantage", "Simon", "Dana", "Nate", "Hugo"]
name_rows = [r for r in rows if any(re.search(r"\b" + n + r"\b", r["_target"]) for n in NAMES)]
for _ in range(int(900 * SCALE) + (12 if MODE != "train" else 0)):
    if name_rows and rng.random() < 0.5:
        r = rng.choice(name_rows)
        n = next(n for n in NAMES if re.search(r"\b" + n + r"\b", r["_target"]))
        if n not in r["_raw"]:
            continue
        raw, target, app, c = r["_raw"].replace(n, misspell(n)), r["_target"], app_of(r), ctx_for(r)
    else:  # synthetic: a greeting or mention with a name
        n = rng.choice(NAMES)
        s0 = rng.choice(short)
        tmpl = rng.choice([("hi {n} {s}", "Hi {n}, {s}"), ("hello mr {n} {s}", "Hello Mr. {n}, {s}"),
                           ("can you ask {n} about this {s}", "Can you ask {n} about this? {s}"),
                           ("{s} loop in {n} please", "{s} Loop in {n}, please.")])
        raw = tmpl[0].format(n=misspell(n), s=spoken(s0))
        target = tmpl[1].format(n=n, s=lead(s0["_target"]))
        app, c = rng.choice([("Slack", "work chat"), ("Gmail", "email"), ("Claude", "AI assistant prompt")]), None
    distract = rng.sample([x for x in NAMES if x != n], 3)
    vocab = [n] + distract
    rng.shuffle(vocab)
    out["H"].append(example(app, raw, target, vocab, ctx=c))

# I. Misheard sign-offs in email: the name after "regards" is the user's own name.
out["I"] = []
MISHEARD_KAI = ["hi", "sky", "guy", "kay", "chi", "kite", "car", "pie", "high", "kye"]
for _ in range(int(400 * SCALE) + (10 if MODE != "train" else 0)):
    so_raw, so_t = rng.choice([("regards", "Regards"), ("regard", "Regards"), ("best regards", "Best regards"),
                               ("thanks", "Thanks"), ("cheers", "Cheers"), ("kind regards", "Kind regards")])
    body = rng.sample(short, rng.randint(1, 2))
    raw = " ".join(spoken(b) for b in body) + rng.choice([". ", " "]) + so_raw + rng.choice([" ", ". ", ", "]) \
        + rng.choice(MISHEARD_KAI) + rng.choice(["", "."])
    target = " ".join(lead(b["_target"]) for b in body) + f"\n\n{so_t},\nKai"
    c = random_ctx(("Gmail", "email")); c["user"] = USER
    out["I"].append(example(rng.choice(EMAIL_APPS), raw, target, vocab=["Kai Kaushik", "Kai"], ctx=c))

# J. Spoken times, including a correction between two times.
out["J"] = []
def say_time():
    h, m = rng.randint(1, 12), rng.choice([0, 0, 15, 30, 45, 5, 20])
    ap = rng.choice(["am", "pm", ""])
    spoken_t = f"{h} {m:02d}" if m else f"{h}"
    written = f"{h}:{m:02d}" if m else f"{h}"
    if ap:
        spoken_t += " " + rng.choice([ap, ap[0] + " m", ap.upper(), ap[0] + "." + ap[1] + "."])
        written += " " + ap
    return spoken_t, written
for _ in range(int(400 * SCALE) + (10 if MODE != "train" else 0)):
    t1s, t1w = say_time()
    lead_in = rng.choice([("let's meet at", "Let's meet at"), ("the call is at", "The call is at"),
                          ("i'll be there by", "I'll be there by"), ("can we do", "Can we do")])
    if rng.random() < 0.4:
        t2s, t2w = say_time()
        raw = f"{lead_in[0]} {t1s} {rng.choice(['sorry make that', 'no wait', 'actually', 'sorry'])} {t2s}"
        target = f"{lead_in[1]} {t2w}"
    else:
        raw, target = f"{lead_in[0]} {t1s}", f"{lead_in[1]} {t1w}"
    target += "?" if lead_in[0] == "can we do" else "."
    if rng.random() < 0.6:  # followed by more speech
        s0 = rng.choice(short)
        raw, target = raw + rng.choice([". ", " "]) + spoken(s0), target + " " + lead(s0["_target"])
    out["J"].append(example(rng.choice([("Slack", "work chat"), ("Gmail", "email"), ("Messages", "personal chat")]),
                            raw, target))

allx = [x for v in out.values() for x in v]
rng.shuffle(allx)
import pathlib
d = pathlib.Path(OUT)
d.mkdir(parents=True, exist_ok=True)
if MODE == "train":
    def is_valid(x):  # stable: depends only on content (methodology rule 4)
        key = x["messages"][1]["content"] + "\x00" + x["messages"][2]["content"]
        return int(hashlib.sha1(key.encode()).hexdigest(), 16) % 40 == 0
    parts = [("train", [x for x in allx if not is_valid(x)]), ("valid", [x for x in allx if is_valid(x)])]
else:
    parts = [(f"{MODE}_suites", allx)]
for name, part in parts:
    with open(d / f"{name}.jsonl", "w") as f:
        for x in part:
            f.write(json.dumps(x, ensure_ascii=False) + "\n")
print(MODE, {k: len(v) for k, v in out.items()}, {n: len(p) for n, p in parts}, f"(sentence pool: {len(short)})")
