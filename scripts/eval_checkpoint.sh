#!/bin/zsh
# Wait for a resumed-run checkpoint (e.g. 0001200), then score it like E10. Usage: eval_checkpoint.sh 0001200
cd "${0:A:h}/.."
STEP=$1
CK=adapters/qwen35-0.8b-kai-v2/${STEP}_adapters.safetensors
until [[ -f $CK ]]; do sleep 30; done
sleep 10
D=adapters/eval-resumed$STEP; mkdir -p $D
cp adapters/qwen35-0.8b-kai-v2/adapter_config.json $D/; cp $CK $D/adapters.safetensors
{ echo "== v2 resumed, step $STEP of 1800"; .venv/bin/python scripts/eval_v2.py mlx-community/Qwen3.5-0.8B-4bit --adapter $D; echo done; } \
  > bench/eval_resumed_$STEP.txt 2>&1
