#!/bin/zsh
# M01: diarization and transcription of the 16 AMI test meetings from one mixed channel (Mix-Headset).
# Outputs: bench/meetings/m01/<engine>/<meeting>.rttm, m01/asr/<meeting>.words.json, and <engine>.log (timings).
# DEV=1 ENGINES="offline sortformer" scripts/meetings/run_m01.sh   (the 12 dev meetings, into m01_dev, for tuning)
set -euo pipefail
ROOT=${0:A:h:h:h}
B=$ROOT/scripts/meetings/MeetBench/.build/release/MeetBench
OUT=$ROOT/bench/meetings/m01${DEV:+_dev}
SDM=~/FluidAudioDatasets/ami_official/${DEV:+dev/}sdm
mkdir -p $OUT/asr
for e in ${=ENGINES:-offline sortformer lseend lseend-ami}; do
  mkdir -p $OUT/$e
  for f in $SDM/*.Mix-Headset.wav; do m=${f:t:r:r}; echo "$f $OUT/$e/$m.rttm"; done > $OUT/$e.list
  $B diarize $e $OUT/$e.list > $OUT/$e.log 2> $OUT/$e.err
done
for f in $SDM/*.Mix-Headset.wav; do m=${f:t:r:r}; echo "$f $OUT/asr/$m.words.json"; done > $OUT/asr.list
$B transcribe $OUT/asr.list > $OUT/asr.log 2> $OUT/asr.err
echo done
