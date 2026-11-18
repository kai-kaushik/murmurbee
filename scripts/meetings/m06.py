"""M06: one real call (meetbench record) to a transcript and meeting notes, all on this Mac.

  mic words    you; the speakers' sound reaching the mic is removed with M04's level filter at -3 dB (chosen on AMI
               dev, not tuned here): a mic word is kept only if it is no more than 3 dB quieter on the mic than in the
               call audio over the same span; then (M04's suggested next filter, added after the level filter left
               28 echoed words on call1) a mic word is also dropped if the call audio has the same word within 1 s
  call words   everyone else (the call audio is what the Mac plays, so it never holds your voice); speakers from the
               offline diarizer
Expects <dir>/mic16.wav, call16.wav (16 kHz mono, aligned), mic.words.json, call.words.json, call.offline.rttm.
Writes <dir>/transcript.txt, bleed.json, and with --notes <dir>/notes.md (Qwen3.5 4B, greedy) plus, when the
call is long enough for more than one part, notes.parts.md (M08's 20-minute part notes, not merged).
Everything stays in bench/meetings/m06/, which git ignores.

M06b, after call 1's notes came out wrong (all post hoc, on that one call):
  dictionary   your MurmurBee dictionary, as dictation uses it: terms that sound like something said are picked
               (Vocabulary.select), "murmur bee" is joined to "Murmurbee" when the letters match a term exactly, a
               misspelt capitalised word close to a term is snapped to it (PostEdit.snapNames), and the picked terms
               go to the notes model as correct spellings
  your name    "You" lines are labelled with the name MurmurBee signs with (Settings), so the notes can say who
  backchannel  a 1-2 word line wedged inside another speaker's turn ("I", "see") is folded away so the turn reads whole
  --fix A=B    your own corrections to the transcript, applied before the notes (like editing the transcript in an app)
  prompt       a summary, then notes in the order things came up with who said each, then action items and
               decisions only when there are any (M05's four fixed sections suited work meetings, not chats)

usage: m06.py DIR [--notes] [--fix "misheard=right" ...] [--model mlx-community/Qwen3.5-4B-4bit | --server URL]
                [--thinking] [--out notes.md]
  --server     an OpenAI-style chat server (llama.cpp's llama-server) instead of MLX, for GGUF models
  --thinking   let the model think first (the model card's sampling: temperature 0.6, top_p 0.95, top_k 20, seed 0);
               otherwise thinking is off and decoding is greedy
"""
import argparse
import json
import re
import subprocess
import urllib.request
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import bleed as bl  # noqa: E402
from score_words import attribute, load_rttm  # noqa: E402
from summarise import CHUNK_PROMPT, chunks  # noqa: E402

DICTIONARY = Path.home() / "Library/Application Support/MurmurBee/dictionary.txt"
ENGLISH = {w.strip().lower() for w in open("/usr/share/dict/words")}

NOTES_PROMPT = """Below is the transcript of a call that {you} recorded. {you}'s lines are labelled {you}; everyone else \
is labelled Speaker 2, Speaker 3, and so on. Each line starts with the time it was said. The transcript comes from \
speech recognition, so expect misheard words and broken sentences; read for what people meant.
{vocab}
Write notes on the call in Markdown:

## Summary
Two to four sentences: what the call was about and what happened, in order.

## Notes
Bullet points in the order things came up. Say who said or did each thing. Keep the specific details people gave: \
names, places, times, numbers and plans.

## Action items
Bullet points: who will do what next. Leave this section out if nobody said they would do anything.

## Decisions
Bullet points: what was agreed. Leave this section out if nothing was agreed.

Only include what the transcript supports. Keep track of who said what: when someone asks a question or calls \
another person something, that is not a description of themselves. Do not guess names, dates or numbers that were \
not said.

Transcript:
{transcript}"""


def dictionary(path=DICTIONARY):
    """Vocabulary.dictionary(): one term per line, '#' starts a comment."""
    if not path.exists():
        return []
    terms = [l.split(" #")[0].strip() for l in path.read_text().splitlines()]
    return [t for t in terms if t and not t.startswith("#") and "@" not in t]


def letters(t):
    return re.sub(r"[^a-z0-9]", "", t.lower())


def similarity(a, b):
    """Vocabulary.similarity: 1 - edit distance / longer length."""
    if not a or not b:
        return 0.0
    prev = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        cur = [i] + [0] * len(b)
        for j in range(1, len(b) + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] != b[j - 1]))
        prev = cur
    return 1 - prev[-1] / max(len(a), len(b))


def select(text, terms, cap=12):
    """Vocabulary.select's near(), with two changes for meetings, where a wrong hint can put a name into the notes:
    a one-word term also matches two or three spoken words whose letters spell it exactly ("murmur bee"), and a
    near match only counts when the spoken word isn't English ("Priyanca", not "march" for Marcal), as in
    PostEdit.snapNames. Closest matches first."""
    words = [letters(w) for w in text.split() if letters(w)]

    def score(term):
        t = letters(term)
        if len(t) < 3:
            return 0
        n, best = len(term.split()), 0
        for i in range(len(words) - n + 1):
            w = "".join(words[i:i + n])
            if w == t:
                return 1
            if w[0] == t[0] and w not in ENGLISH and similarity(w, t) >= 0.6:
                best = max(best, similarity(w, t))
        for k in (n + 1, n + 2):
            if any("".join(words[i:i + k]) == t for i in range(len(words) - k + 1)):
                return 1
        return best
    scored = sorted(((score(t), t) for t in terms), key=lambda x: -x[0])
    return [t for sc, t in scored if sc > 0][:cap]


def snap(words, terms):
    """Join two or three words whose letters spell a term exactly ("murmur bee" -> "Murmurbee"), then
    PostEdit.snapNames: a capitalised word that isn't English and is >= 0.75 similar to a term becomes that term."""
    exact = {letters(t): t for t in terms if " " not in t and len(letters(t)) >= 5}
    out, i = [], 0
    while i < len(words):
        for k in (3, 2):
            joined = "".join(letters(w["w"]) for w in words[i:i + k])
            if len(words[i:i + k]) == k and len({w["spk"] for w in words[i:i + k]}) == 1 and joined in exact:
                tail = re.sub(r"^.*?([^\w]*)$", r"\1", words[i + k - 1]["w"])
                out.append({**words[i], "w": exact[joined] + tail, "e": words[i + k - 1]["e"]})
                i += k
                break
        else:
            w = words[i]
            core = re.sub(r"[^\w]", "", w["w"])
            names = [t for t in terms if t[:1].isupper() and " " not in t and len(t) >= 3]
            if len(core) >= 3 and core[0].isupper() and core.lower() not in ENGLISH and core not in names and names:
                best = max(names, key=lambda t: similarity(core.lower(), t.lower()))
                if similarity(core.lower(), best.lower()) >= 0.75 and best[0].lower() == core[0].lower():
                    w = {**w, "w": w["w"].replace(core, best)}
            out.append(w)
            i += 1
    return out


def turns(words, gap=1.0):
    """summarise.render's turns, then fold a 1-2 word line that sits inside another speaker's turn (both sides
    within 2 s) so the turn reads as one line."""
    lines, cur = [], None
    for w in sorted(words, key=lambda w: w["s"]):
        if cur and w["spk"] == cur["spk"] and w["s"] - cur["e"] <= gap:
            cur["text"].append(w["w"])
            cur["e"] = w["e"]
        else:
            cur = {"spk": w["spk"], "s": w["s"], "e": w["e"], "text": [w["w"]]}
            lines.append(cur)
    i = 1
    while i < len(lines) - 1:
        a, b, c = lines[i - 1], lines[i], lines[i + 1]
        if len(b["text"]) <= 2 and a["spk"] == c["spk"] != b["spk"] and c["s"] - a["e"] <= 2.0:
            a["text"] += c["text"]
            a["e"] = c["e"]
            del lines[i:i + 2]
        else:
            i += 1
    return "\n".join(f"[{int(l['s'] // 60):02d}:{int(l['s'] % 60):02d}] {l['spk']}: {' '.join(l['text'])}"
                     for l in lines)


def sign_name():
    """PostEdit.userNames.first: the name MurmurBee signs with, else the macOS account's first name."""
    r = subprocess.run(["defaults", "read", "com.murmurbee.app", "signName"], capture_output=True, text=True)
    name = r.stdout.strip() or subprocess.run(["id", "-F"], capture_output=True, text=True).stdout.strip()
    return name.split()[0] if name else "You"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--notes", action="store_true")
    ap.add_argument("--fix", action="append", default=[], help="misheard=right, applied to the transcript")
    ap.add_argument("--model", default="mlx-community/Qwen3.5-4B-4bit")
    ap.add_argument("--server")
    ap.add_argument("--thinking", action="store_true")
    ap.add_argument("--out", default="notes.md")
    a = ap.parse_args()
    d = Path(a.dir)
    mic_audio, call_audio = bl.load(d / "mic16.wav"), bl.load(d / "call16.wav")
    mic = json.loads((d / "mic.words.json").read_text())["words"]
    call = json.loads((d / "call.words.json").read_text())["words"]
    level = bl.level_filter(mic, mic_audio, call_audio, -3)
    norm = lambda t: re.sub(r"[^a-z0-9]", "", t.lower())
    kept = [w for w in level if not any(norm(c["w"]) == norm(w["w"]) and abs(c["s"] - w["s"]) < 1.0 for c in call)]
    others = attribute(call, load_rttm(d / "call.offline.rttm"))
    order = {}
    for w in sorted(others, key=lambda w: w["s"]):
        order.setdefault(w["spk"], f"Speaker {len(order) + 2}")
    you = sign_name()
    words = sorted([{**w, "spk": you} for w in kept] + [{**w, "spk": order[w["spk"]]} for w in others],
                   key=lambda w: w["s"])
    terms = dictionary()
    vocab = select(" ".join(w["w"] for w in words), terms)
    if you not in vocab:
        vocab.append(you)
    text = turns(snap(words, vocab))
    for f in a.fix:
        wrong, right = f.split("=", 1)
        text = re.sub(re.escape(wrong), right, text, flags=re.IGNORECASE)
    (d / "transcript.txt").write_text(text + "\n")
    stats = {"audio_s": round(len(call_audio) / bl.RATE, 1), "mic_words": len(mic), "mic_after_level": len(level), "mic_kept": len(kept),
             "call_words": len(call), "call_speakers": len(order), "dictionary_terms": len(terms),
             "terms_picked": len(vocab), "fixes": len(a.fix)}
    (d / "bleed.json").write_text(json.dumps(stats, indent=2) + "\n")
    print(json.dumps(stats))
    if not a.notes:
        return

    def strip(text):
        return re.sub(r"(?s)^.*</think>", "", text).strip()

    if a.server:
        def generate(content, max_tokens):
            body = {"messages": [{"role": "user", "content": content}], "max_tokens": max_tokens + (8000 if a.thinking else 0),
                    "chat_template_kwargs": {"enable_thinking": a.thinking}, "seed": 0}
            body.update({"temperature": 0.6, "top_p": 0.95, "top_k": 20} if a.thinking else {"temperature": 0})
            req = urllib.request.Request(a.server.rstrip("/") + "/v1/chat/completions", json.dumps(body).encode(),
                                         {"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=3600) as r:
                return strip(json.loads(r.read())["choices"][0]["message"]["content"])
    else:
        import mlx.core as mx
        from mlx_lm import load, stream_generate
        from mlx_lm.sample_utils import make_sampler
        model, tok = load(a.model)
        mx.random.seed(0)
        sampler = make_sampler(temp=0.6, top_p=0.95, top_k=20) if a.thinking else make_sampler(temp=0.0)

        def generate(content, max_tokens):
            prompt = tok.apply_chat_template([{"role": "user", "content": content}], add_generation_prompt=True,
                                             enable_thinking=a.thinking)
            budget = max_tokens + (8000 if a.thinking else 0)
            return strip("".join(r.text for r in stream_generate(model, tok, prompt, max_tokens=budget, sampler=sampler)))

    hint = (f"\nThese names and words may come up; this is how they are spelled (speech recognition may have misheard "
            f"them as something that sounds similar): {', '.join(vocab)}.\n")
    (d / a.out).write_text(generate(NOTES_PROMPT.format(you=you, vocab=hint, transcript=text), 1200) + "\n")
    labels = ("Speakers are labelled Speaker 1, Speaker 2, and so on",
              f"Speakers are labelled {you} (who recorded the call) and Speaker 2, Speaker 3, and so on")
    parts = chunks(text, 20)
    if len(parts) > 1:
        notes = [f"# Part {i} of {len(parts)} (minutes {s0} to {s1})\n\n"
                 + generate(CHUNK_PROMPT.replace(*labels).format(i=i, n=len(parts), start=s0, end=s1, transcript=p), 800)
                 for i, (s0, s1, p) in enumerate(parts, 1)]
        (d / "notes.parts.md").write_text("\n\n".join(notes) + "\n")
    print("notes written")


if __name__ == "__main__":
    main()
