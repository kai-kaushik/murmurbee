"""Prompt format v2 for the cleanup model. The Swift app (Engines.swift, PromptV2) must mirror this exactly.

user message:
    app=<name> type=<type>
    vocab: <term>; <term>; ...          (optional: dictionary + on-screen names worth spelling right)
    <before>...</before>                (optional: text already in the field / already written this dictation)
    <transcript>...</transcript>

The model returns only the text to append. Pieces are joined with `join()`.
"""
import re

SYSTEM = "Clean up this dictated transcript. Output only the cleaned text."
BEFORE_CHARS = 200
MAX_VOCAB = 12

LIST_START = re.compile(r"^(\d+\.|[-•]) ")
SIGNOFF = re.compile(r"^(Regards|Best regards|Kind regards|Warm regards|Best|Thanks|Many thanks|Thank you|Cheers)\b[,!]?\s*\n")


def user_message(app_name, app_type, raw, vocab=(), before=""):
    lines = [f"app={app_name} type={app_type}"]
    if vocab:
        lines.append("vocab: " + "; ".join(list(vocab)[:MAX_VOCAB]))
    before = before[-BEFORE_CHARS:].strip()
    if before:
        lines.append(f"<before>{before}</before>")
    lines.append(f"<transcript>{raw.strip()}</transcript>")
    return "\n".join(lines)


def join(written, piece, app_type):
    """How the app appends a cleaned chunk to what's already been written this dictation."""
    piece = piece.strip()
    if not written:
        return piece
    if not piece:
        return written
    last_line = written.rstrip().rsplit("\n", 1)[-1]
    if LIST_START.match(piece):
        sep = "\n" if not written.endswith("\n") else ""
    elif app_type == "email" and SIGNOFF.match(piece + "\n"):
        sep = "\n\n"
    elif LIST_START.match(last_line) and piece[0].isupper():
        sep = "\n\n"  # a new sentence after a list starts a new paragraph; lowercase continues the item
    else:
        sep = " "
    return written.rstrip(" ") + sep + piece
