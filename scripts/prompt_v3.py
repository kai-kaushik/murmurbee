"""Prompt format v3 (E13+): the full context the app knows when you dictate. The Swift app (PromptV3 in
Engines.swift) must build exactly this. Lines are omitted when empty, in this order:

    app=<name> type=<type>
    user=<name you sign with>
    locale=<en-GB> tz=<UTC+01:00> time=<Sun 25 Oct 2026 10:30>
    url=<host/path, browsers only>
    vocab: <term>; <term>; ...
    <selected>...</selected>
    <before>...</before>
    <after>...</after>
    <transcript>...</transcript>

The model returns only the text to insert. Chunks are joined with `join()` (mirrors PromptV2.join + the app's
false-full-stop rule).
"""
import re

SYSTEM = "Clean up this dictated transcript. Output only the cleaned text."
BEFORE_CHARS, AFTER_CHARS, SELECTED_CHARS, MAX_VOCAB = 200, 120, 300, 12


def user_message(app_name, app_type, raw, vocab=(), before="", *, user="", locale="", tz="", time="", url="",
                 selected="", after=""):
    lines = [f"app={app_name} type={app_type}"]
    if user:
        lines.append(f"user={user}")
    when = " ".join(x for x in [f"locale={locale}" if locale else "", f"tz={tz}" if tz else "",
                                f"time={time}" if time else ""] if x)
    if when:
        lines.append(when)
    if url:
        lines.append(f"url={url}")
    if vocab:
        lines.append("vocab: " + "; ".join(list(vocab)[:MAX_VOCAB]))
    for tag, text, n, tail in [("selected", selected, SELECTED_CHARS, False), ("before", before, BEFORE_CHARS, True),
                               ("after", after, AFTER_CHARS, False)]:
        t = (text[-n:] if tail else text[:n]).strip()
        if t:
            lines.append(f"<{tag}>{t}</{tag}>")
    lines.append(f"<transcript>{raw.strip()}</transcript>")
    return "\n".join(lines)


def tz_label(offset_minutes_js):
    """Wispr stores JS getTimezoneOffset() (minutes, sign inverted: -60 = UTC+1)."""
    m = -int(offset_minutes_js)
    sign = "+" if m >= 0 else "-"
    return f"UTC{sign}{abs(m) // 60:02d}:{abs(m) % 60:02d}"


def clean_url(url):
    if not url or url == "unknown":
        return ""
    u = re.sub(r"^[a-z]+://", "", url).split("?")[0].split("#")[0]
    parts = u.split("/")
    return "/".join(parts[:2])[:60]


LIST_START = re.compile(r"^(\d+\.|[-•]) ")
SIGNOFF = re.compile(r"^(Regards|Best regards|Kind regards|Warm regards|Best|Thanks|Many thanks|Thank you|Cheers)\b[,!]?\s*\n")
ABBREV = {"mr.", "mrs.", "ms.", "dr.", "a.m.", "p.m.", "etc.", "e.g.", "i.e.", "vs.", "st."}


def join(written, piece, app_type):
    piece = piece.strip()
    if not written:
        return piece
    if not piece:
        return written
    w = written.rstrip(" ")
    last_word = w.split()[-1].lower() if w.split() else ""
    if w.endswith(".") and piece[0].islower() and last_word not in ABBREV and last_word.count(".") == 1:
        w = w[:-1]  # speech recognition ends every chunk with "."; a lowercase continuation means it was false
    last_line = w.rstrip().rsplit("\n", 1)[-1]
    if LIST_START.match(piece):
        sep = "\n" if not w.endswith("\n") else ""
    elif app_type == "email" and SIGNOFF.match(piece + "\n"):
        sep = "\n\n"
    elif LIST_START.match(last_line) and piece[0].isupper():
        sep = "\n\n"
    else:
        sep = " "
    return w + sep + piece
