#!/bin/zsh
# M05: notes for the 12 scenario meetings from five local models, from the manual transcript (gold) and from the
# app's own transcript (pipeline: Parakeet Ultra + offline diarizer, M01). Run with nothing else heavy running.
set -uo pipefail
ROOT=${0:A:h:h:h}
PY=$ROOT/.venv/bin/python
for model in Qwen3.5-2B-4bit gemma-4-e2b-it-4bit Qwen3.5-4B-4bit gemma-4-e4b-it-4bit Qwen3.5-9B-4bit; do
  for c in pipeline gold; do
    $PY $ROOT/scripts/meetings/summarise.py mlx-community/$model --condition $c 2>&1 | grep '^{' || echo "FAILED $model $c"
  done
done
echo done
