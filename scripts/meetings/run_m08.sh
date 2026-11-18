#!/bin/zsh
# M08: chunk-then-merge notes with Qwen3.5 4B. Stage "dev" picks the part length on the dev meetings (gold
# transcript, single pass vs 5/10/20-minute parts); stage "test" runs the chosen length on the test meetings,
# both transcripts, for comparison with M05's single pass. Coverage is scored by the M05 referee (Gemma 4
# 26B-A4B), coverage only. Stage "m08b" separates note length from splitting (see the log). Run with nothing else heavy running.
set -uo pipefail
ROOT=${0:A:h:h:h}
PY=$ROOT/.venv/bin/python
M=mlx-community/Qwen3.5-4B-4bit
OUT=$ROOT/bench/meetings/m08
REF=mlx-community/gemma-4-26b-a4b-it-4bit
case ${1:-dev} in
dev)
  for n in 0 5 10 20; do
    $PY $ROOT/scripts/meetings/summarise.py $M --dev --chunk-minutes $n --out $OUT/dev/chunk$n 2>&1 | grep '^{' || echo "FAILED chunk$n"
  done
  $PY $ROOT/scripts/meetings/referee.py $REF --dev --coverage-only $OUT/dev/chunk{0,5,10,20} 2>&1 | grep --line-buffered -v Fetching
  ;;
test)
  n=${CHUNK:?set CHUNK to the part length chosen on dev}
  for c in gold pipeline; do
    $PY $ROOT/scripts/meetings/summarise.py $M --condition $c --chunk-minutes $n --out $OUT/test/chunk$n/$c 2>&1 | grep '^{' || echo "FAILED $c"
  done
  $PY $ROOT/scripts/meetings/referee.py $REF --coverage-only $OUT/test/chunk$n/{gold,pipeline} 2>&1 | grep --line-buffered -v Fetching
  ;;
m08b)
  # (a) 20-minute parts with a merge that only removes repeats; (b) one pass asked for thorough notes.
  $PY $ROOT/scripts/meetings/summarise.py $M --dev --chunk-minutes 20 --merge dedup --out $OUT/dev/dedup20 2>&1 | grep '^{' || echo "FAILED dedup20"
  $PY $ROOT/scripts/meetings/summarise.py $M --dev --thorough --out $OUT/dev/thorough 2>&1 | grep '^{' || echo "FAILED thorough"
  $PY $ROOT/scripts/meetings/referee.py $REF --dev --coverage-only $OUT/dev/{dedup20,thorough} 2>&1 | grep --line-buffered -v Fetching
  ;;
esac
echo done
