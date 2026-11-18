#!/bin/zsh
# M05 scoring: the referee (Gemma 4 26B-A4B; the 35B swapped on a 32 GB Mac with other apps open) over all 10 notes folders (5 models x gold/pipeline). Referee speed is not a result.
set -uo pipefail
ROOT=${0:A:h:h:h}
DIRS=($ROOT/bench/meetings/m05/*/{gold,pipeline})
for ref in ${=REFEREES:-gemma-4-26b-a4b-it-4bit}; do
  $ROOT/.venv/bin/python $ROOT/scripts/meetings/referee.py mlx-community/$ref $DIRS 2>&1 | grep --line-buffered -v Fetching || echo "FAILED $ref"
done
echo done
