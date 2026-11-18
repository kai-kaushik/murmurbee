#!/bin/zsh
# M09 scoring: Qwen3.5-35B-A3B (wrote none of the notes) over the four notes folders: faithfulness with retrieved
# passages (faithful.py), then coverage of AMI's human summaries (referee.py, M05's question). Both resume.
set -uo pipefail
ROOT=${0:A:h:h:h}
PY=$ROOT/.venv/bin/python
REF=mlx-community/Qwen3.5-35B-A3B-4bit
DIRS=($ROOT/bench/meetings/m05/Qwen3.5-4B-4bit/pipeline $ROOT/bench/meetings/m09/*/pipeline)
$PY $ROOT/scripts/meetings/faithful.py $REF $DIRS 2>&1 | grep --line-buffered -v -i "fetching\|warning" || echo "FAILED faithful"
$PY $ROOT/scripts/meetings/referee.py $REF --coverage-only $DIRS 2>&1 | grep --line-buffered -v -i "fetching\|warning" || echo "FAILED coverage"
echo done
