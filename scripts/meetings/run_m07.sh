#!/bin/zsh
# M07: live notes on the 16 test mixes. Live speaker labels (Sortformer ~1 s and ~2 s behind), then streaming
# Parakeet Unified at two latency tiers. Outputs bench/meetings/m07/<engine>/<meeting>.{rttm,json} and <engine>.log.
# Word delay is measured in audio time and is not affected by other load; the logged speeds are only valid when
# run with nothing else heavy running.
set -uo pipefail
ROOT=${0:A:h:h:h}
B=$ROOT/scripts/meetings/MeetBench/.build-m07/release/MeetBench
OUT=$ROOT/bench/meetings/m07
SDM=~/FluidAudioDatasets/ami_official/sdm
for e in ${=DIARIZERS:-sortformer-balanced sortformer-efficient}; do
  mkdir -p $OUT/$e
  for f in $SDM/*.Mix-Headset.wav; do m=${f:t:r:r}; echo "$f $OUT/$e/$m.rttm"; done > $OUT/$e.list
  $B diarize $e $OUT/$e.list > $OUT/$e.log 2> $OUT/$e.err || echo "FAILED $e"
done
for e in ${=STREAMS:-unified-1120 unified-320}; do
  mkdir -p $OUT/$e
  for f in $SDM/*.Mix-Headset.wav; do m=${f:t:r:r}; [[ -s $OUT/$e/$m.json ]] || echo "$f $OUT/$e/$m.json"; done > $OUT/$e.list
  $B stream $e $OUT/$e.list >> $OUT/$e.log 2>> $OUT/$e.err || echo "FAILED $e"
done
echo done
