#!/bin/zsh
# M02: the simulated calls (make_calls.py). Both channels are transcribed; only the others channel is diarized
# (everything on the mic channel is "you"). No model is told how many people are in the meeting.
# ENGINES="offline lseend-ami" scripts/meetings/run_m02.sh        (DEV=1: the dev meetings, for tuning)
set -euo pipefail
ROOT=${0:A:h:h:h}
B=$ROOT/scripts/meetings/MeetBench/.build/release/MeetBench
OUT=$ROOT/bench/meetings/m02${DEV:+_dev}
CALLS=~/FluidAudioDatasets/ami_official/${DEV:+dev/}calls
mkdir -p $OUT/asr
for f in $CALLS/*.wav; do n=${f:t:r}; [[ -f $OUT/asr/$n.words.json ]] || echo "$f $OUT/asr/$n.words.json"; done > $OUT/asr.list
[[ -s $OUT/asr.list ]] && $B transcribe $OUT/asr.list >> $OUT/asr.log 2>> $OUT/asr.err
for e in ${=ENGINES:-offline}; do
  mkdir -p $OUT/$e
  for f in $CALLS/*.others.wav; do n=${f:t:r}; echo "$f $OUT/$e/$n.rttm"; done > $OUT/$e.list
  $B diarize $e $OUT/$e.list > $OUT/$e.log 2> $OUT/$e.err
done
echo done
