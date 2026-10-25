"""Export Kai's Wispr Flow history into a local eval set.

Read-only against Wispr's database. Writes:
  data/wispr-golden/audio/<id>.wav   rows that still have audio
  data/wispr-golden/audio.jsonl      labels for those clips
  data/wispr-golden/text.jsonl       every row's text pairs (for cleanup eval)
"""
import json
import pathlib
import sqlite3
import sys

SRC = pathlib.Path.home() / "Library/Application Support/Wispr Flow/flow.sqlite"
OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "data/wispr-golden")

FIELDS = [
    "transcriptEntityId", "timestamp", "app", "url", "duration", "speechDuration",
    "language", "detectedLanguage", "asrText", "formattedText", "pastedText",
    "editedText", "editDistanceToDictated", "numWordsCorrected", "transcriptOrigin",
    "e2eLatency", "clientNetworkLatency", "personalizationStyleSettings", "status", "timezoneOffsetMinutes",
]
# Context Wispr captured at key-down: screen names (ax_context), dictionary, text before the cursor.
CONTEXT_SQL = """, json_extract(additionalContext, '$.ax_context') AS axContext,
  json_extract(additionalContext, '$.dictionary_context') AS dictionaryContext,
  json_extract(additionalContext, '$.textbox_contents.beforeText') AS beforeText,
  json_extract(additionalContext, '$.textbox_contents.selectedText') AS selectedText,
  json_extract(additionalContext, '$.textbox_contents.afterText') AS afterText,
  json_extract(additionalContext, '$.user_first_name') || ' ' || json_extract(additionalContext, '$.user_last_name') AS userName"""
CTX_FIELDS = ["axContext", "dictionaryContext", "beforeText", "selectedText", "afterText", "userName"]


def main() -> None:
    (OUT / "audio").mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(f"file:{SRC}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    cols = ", ".join(FIELDS) + CONTEXT_SQL

    n_text = 0
    with open(OUT / "text.jsonl", "w") as f:
        for row in db.execute(f"SELECT {cols} FROM History WHERE asrText IS NOT NULL AND asrText <> '' ORDER BY timestamp"):
            f.write(json.dumps({k: row[k] for k in FIELDS + CTX_FIELDS}, ensure_ascii=False) + "\n")
            n_text += 1

    n_audio, seconds = 0, 0.0
    with open(OUT / "audio.jsonl", "w") as f:
        q = f"SELECT {cols}, audio FROM History WHERE length(audio) > 0 ORDER BY timestamp"
        for row in db.execute(q):
            rid = row["transcriptEntityId"]
            path = OUT / "audio" / f"{rid}.wav"
            path.write_bytes(row["audio"])
            rec = {k: row[k] for k in FIELDS + CTX_FIELDS}
            rec["audioPath"] = str(path.relative_to(OUT))
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            n_audio += 1
            seconds += row["duration"] or 0

    print(f"text rows: {n_text}  audio clips: {n_audio}  audio hours: {seconds / 3600:.1f}  -> {OUT}")


if __name__ == "__main__":
    main()
