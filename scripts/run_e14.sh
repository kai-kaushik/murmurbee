#!/bin/zsh
# E14: wait for E13's evaluation to finish (the GPU is shared), train the public model, then score it.
# Checkpoints are chosen on Kai's private dev clips; the best one and the v3 baseline are then scored on the
# private test clips + suites and on the public synthetic suite. Results in bench/e14/.
cd "${0:A:h}/.."
while pgrep -f "run_e13_eval.sh|mlx_lm lora -c data/sft4/e13.yaml" >/dev/null; do sleep 60; done
nice -n 10 .venv/bin/python -m mlx_lm lora -c data/public/e14.yaml > bench/e14/train.log 2>>bench/stderr.log
[[ -f adapters/e14/0002000_adapters.safetensors ]] || { echo "E14 training failed; see bench/e14/train.log"; exit 1; }
EV() { nice -n 5 .venv/bin/python scripts/eval_v4.py "$@" --chunked; }
for step in 0002000 0003000 0004000 0005000; do
  [[ -f adapters/e14/${step}_adapters.safetensors ]] || continue
  d=adapters/e14-eval-$step; mkdir -p $d; cp adapters/e14/adapter_config.json $d/; cp adapters/e14/${step}_adapters.safetensors $d/adapters.safetensors
  EV mlx-community/Qwen3.5-0.8B-4bit --adapter $d --prompt v3 --split dev --suites data/sft4 --json bench/e14/dev_$step.json > bench/e14/dev_$step.txt 2>>bench/stderr.log
done
best=$(.venv/bin/python -c "
import json,glob
c={f.split('_')[-1][:-5]:json.load(open(f))['clips']['ALL']['wer'] for f in glob.glob('bench/e14/dev_0*.json')}
print(min(c,key=c.get))")
echo $best > bench/e14/best_step.txt
B=adapters/e14-eval-$best
EV mlx-community/Qwen3.5-0.8B-4bit --adapter $B --prompt v3 --split test --suites data/sft4 --json bench/e14/test_best.json > bench/e14/test_best.txt 2>>bench/stderr.log
EV mlx-community/Qwen3.5-0.8B-4bit --adapter $B --prompt v3 --split test --suites data/public --json bench/e14/public_best.json > bench/e14/public_best.txt 2>>bench/stderr.log
EV models/qwen35-0.8b-kai-v3 --prompt v2 --split test --suites data/public --json bench/e14/public_v3.json > bench/e14/public_v3.txt 2>>bench/stderr.log
EV mlx-community/Qwen3.5-0.8B-4bit --prompt v3 --split test --suites data/public --json bench/e14/public_base.json > bench/e14/public_base.txt 2>>bench/stderr.log
echo "E14 complete, best dev checkpoint: $best"
