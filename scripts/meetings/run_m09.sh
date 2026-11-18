#!/bin/zsh
# M09: notes for the 12 AMI test meetings (pipeline transcript, M05's prompt, greedy, thinking off) from the three
# models that did best on call 1 (M06c). Qwen3.5 4B's are M05's. One model at a time; Saluki through llama-server.
set -uo pipefail
ROOT=${0:A:h:h:h}
PY=$ROOT/.venv/bin/python
OUT=$ROOT/bench/meetings/m09
HUB=~/.cache/huggingface/hub
POODLE=($HUB/models--ConwayResearch--Underdog-Poodle-4B/snapshots/*/mlx)
SALUKI=($HUB/models--ConwayResearch--Underdog-Saluki-27B-1.0/snapshots/*/Underdog-Saluki-27B-1.0-IQ2-mix.gguf)

$PY $ROOT/scripts/meetings/summarise.py mlx-community/gemma-4-26b-a4b-it-4bit --condition pipeline \
  --out $OUT/gemma-4-26b-a4b-it-4bit/pipeline 2>&1 | grep '^{' || echo "FAILED gemma"
$PY $ROOT/scripts/meetings/summarise.py $POODLE[1] --condition pipeline \
  --out $OUT/Underdog-Poodle-4B/pipeline 2>&1 | grep '^{' || echo "FAILED poodle"

llama-server -m $SALUKI[1] --jinja -ngl 99 -fa on -c 16384 --port 8091 > $OUT/llama-server.log 2>&1 &
SERVER=$!
until curl -sf localhost:8091/health > /dev/null; do sleep 5; done
$PY $ROOT/scripts/meetings/summarise.py Underdog-Saluki-27B-IQ2 --server http://localhost:8091 --condition pipeline \
  --out $OUT/Underdog-Saluki-27B-IQ2/pipeline 2>&1 | grep '^{' || echo "FAILED saluki"
kill $SERVER
echo done
