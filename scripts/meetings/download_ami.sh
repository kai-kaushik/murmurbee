#!/bin/zsh
# Downloads the official AMI test set (16 meetings, the NeMo/pyannote split) for the meeting-notes experiments:
# the headset mix (one channel with everyone) and each participant's own headset, plus the manual annotations.
# AMI Meeting Corpus, CC BY 4.0, University of Edinburgh. ~4 GB into ~/FluidAudioDatasets/ami_official,
# where FluidAudio's benchmark CLI also looks.
set -euo pipefail
BASE=https://groups.inf.ed.ac.uk/ami
OUT=~/FluidAudioDatasets/ami_official
mkdir -p $OUT/sdm $OUT/ihm_all $OUT/annotations
MEETINGS=(EN2002a EN2002b EN2002c EN2002d ES2004a ES2004b ES2004c ES2004d
          IS1009a IS1009b IS1009c IS1009d TS3003a TS3003b TS3003c TS3003d)
jobs=()
for m in $MEETINGS; do
  jobs+=("$BASE/AMICorpusMirror/amicorpus/$m/audio/$m.Mix-Headset.wav $OUT/sdm/$m.Mix-Headset.wav")
  for h in 0 1 2 3; do
    jobs+=("$BASE/AMICorpusMirror/amicorpus/$m/audio/$m.Headset-$h.wav $OUT/ihm_all/$m.Headset-$h.wav")
  done
done
jobs+=("$BASE/AMICorpusAnnotations/ami_public_manual_1.6.2.zip $OUT/annotations/ami_public_manual_1.6.2.zip")
printf '%s\n' $jobs | xargs -P 6 -L 1 sh -c 'curl -sfL -C - -o "$1" "$0" || echo "FAILED $0"'
# The Edinburgh server sometimes drops connections mid-file: compare every file with the server's size and resume.
for f in $OUT/sdm/*.wav $OUT/ihm_all/*.wav; do
  n=${f:t}; url=$BASE/AMICorpusMirror/amicorpus/${n%%.*}/audio/$n
  want=$(curl -sIL $url | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')
  for try in 1 2 3; do [[ $(stat -f %z $f) == $want ]] && break; curl -sfL -C - -o $f $url || true; done
  [[ $(stat -f %z $f) == $want ]] || echo "INCOMPLETE $f"
done
cd $OUT/annotations && unzip -qo ami_public_manual_1.6.2.zip
# Reference speaker turns and scoring regions: pyannote's AMI setup ("only_words" RTTMs, test split).
mkdir -p $OUT/ref/rttm $OUT/ref/uem
PY=https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main
for m in $MEETINGS; do
  curl -sfL -o $OUT/ref/rttm/$m.rttm $PY/only_words/rttms/test/$m.rttm
  curl -sfL -o $OUT/ref/uem/$m.uem $PY/uems/test/$m.uem
done
echo "done: $(ls $OUT/sdm | wc -l) mixes, $(ls $OUT/ihm_all | wc -l) headsets, $(ls $OUT/ref/rttm | wc -l) references"
