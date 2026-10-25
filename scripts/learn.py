"""Learn from Kai's edits in MurmurBee's history.

For each dictation where the app captured the field right after pasting (field_after) and again later
(field_later), find what Kai changed inside the text we inserted:
  - store it as edited_text (the training target for the next fine-tune)
  - single-word corrections that look like names (capitalised, sound like the original) are appended to
    ~/Library/Application Support/MurmurBee/dictionary.txt, tagged "# auto"

Usage: python scripts/learn.py            (dry run: prints what it would learn)
       python scripts/learn.py --apply
"""
import difflib
import pathlib
import re
import sqlite3
import sys

APP = pathlib.Path.home() / "Library/Application Support/MurmurBee"
DB, DICT = APP / "history.sqlite", APP / "dictionary.txt"
apply = "--apply" in sys.argv


def edited_span(inserted, after, later):
    """The inserted text as it reads in `later`, located via the unchanged text around it in `after`."""
    i = after.find(inserted)
    if i < 0:
        return None
    prefix, suffix = after[:i], after[i + len(inserted):]
    if not later.startswith(prefix[-200:] if len(prefix) > 200 else prefix) and prefix and prefix[-40:] not in later:
        return None
    start = later.find(prefix[-40:]) + len(prefix[-40:]) if prefix else 0
    end = later.find(suffix[:40], start) if suffix else len(later)
    if start < 0 or end < start:
        return None
    return later[start:end].strip()


def word_fixes(a, b):
    aw, bw = a.split(), b.split()
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, aw, bw).get_opcodes():
        if tag == "replace" and i2 - i1 <= 2 and j2 - j1 <= 2:
            old, new = " ".join(aw[i1:i2]).strip(".,!?"), " ".join(bw[j1:j2]).strip(".,!?")
            if new[:1].isupper() and difflib.SequenceMatcher(None, old.lower(), new.lower()).ratio() >= 0.5:
                yield old, new


db = sqlite3.connect(DB)
rows = db.execute("SELECT id, cleaned_text, field_after, field_later FROM dictations "
                  "WHERE field_after IS NOT NULL AND field_later IS NOT NULL AND field_after != field_later").fetchall()
known = set(DICT.read_text().splitlines()) if DICT.exists() else set()
new_terms, n_edits = [], 0
for rid, inserted, after, later in rows:
    span = edited_span(inserted.strip(), after, later)
    if not span or span == inserted.strip():
        continue
    n_edits += 1
    print(f"#{rid} edited:\n  ours : {inserted[:160]}\n  yours: {span[:160]}")
    if apply:
        db.execute("UPDATE dictations SET edited_text = ? WHERE id = ?", (span, rid))
    for old, new in word_fixes(inserted, span):
        if new not in known and new not in new_terms and new.lower() != old.lower():
            new_terms.append(new)
            print(f"  -> dictionary: {new}  (was heard as '{old}')")

if apply:
    db.commit()
    if new_terms:
        with open(DICT, "a") as f:
            f.write("".join(f"{t}  # auto\n" for t in new_terms))
print(f"\n{len(rows)} dictations with a later read, {n_edits} edited, {len(new_terms)} new dictionary terms"
      + ("" if apply else "  (dry run; pass --apply to save)"))
