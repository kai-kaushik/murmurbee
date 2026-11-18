#!/bin/zsh
# Packages an MLX model folder as the app's notes model, ready to attach to a GitHub release.
# usage: package_notes_model.sh <model dir> <out.zip>
# Then set ModelStore.notes (name, URL, parts) and ModelStore.notesSHA256 to what this prints.
# The image encoder is left out: the app loads text only (Qwen35 sanitize drops it anyway), and without it the
# package fits under GitHub's 2 GiB limit for release files.
set -euo pipefail
SRC=$1 OUT=${2:A}
ROOT=${0:A:h:h:h}
STAGE=$(mktemp -d)
trap 'rm -rf $STAGE' EXIT
cp -RL $SRC $STAGE/notes  # Hugging Face's cache is all symlinks
chmod -R u+w $STAGE/notes  # and its files are read-only
$ROOT/.venv/bin/python - $STAGE/notes <<'PY'
import json, sys
from pathlib import Path
import mlx.core as mx
d = Path(sys.argv[1])
index = json.loads((d / "model.safetensors.index.json").read_text())
for name in sorted(set(index["weight_map"].values())):
    weights, meta = mx.load(str(d / name), return_metadata=True)
    kept = {k: v for k, v in weights.items() if not k.startswith(("vision_tower", "model.visual"))}
    mx.save_safetensors(str(d / name), kept, metadata=meta)
index["weight_map"] = {k: v for k, v in index["weight_map"].items() if not k.startswith(("vision_tower", "model.visual"))}
(d / "model.safetensors.index.json").write_text(json.dumps(index, indent=2))
PY
# Files for images and video, and vocab.json, which tokenizer.json already holds.
rm -f $STAGE/notes/{preprocessor_config,processor_config,video_preprocessor_config,vocab}.json $STAGE/notes/.gitattributes
print '{"rank": 1}' > $STAGE/notes/localflow.json
rm -f $OUT
ditto -c -k --zlibCompressionLevel 9 --keepParent $STAGE/notes $OUT
ls -l $OUT | awk '{print $5, "bytes"}'
shasum -a 256 $OUT
# GitHub refuses release files over 2 GiB, so the zip goes up in two parts, <out>.1 and <out>.2 (Remote.parts).
python3 - $OUT <<'PY'
import os, sys
path = sys.argv[1]
half = (os.path.getsize(path) + 1) // 2
with open(path, "rb") as f:
    for i in (1, 2):
        with open(f"{path}.{i}", "wb") as out:
            left = half
            while left and (chunk := f.read(min(left, 64 << 20))):
                out.write(chunk)
                left -= len(chunk)
PY
ls -l $OUT.1 $OUT.2 | awk '{print $5, $9}'
