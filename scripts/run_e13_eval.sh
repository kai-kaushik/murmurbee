#!/bin/zsh
# E13 evaluation: wait for training, score checkpoints + the v3 baseline on dev (chunked, each model in its own
# prompt format), then the best checkpoint and the baseline on test. Results in bench/e13/.
cd "${0:A:h}/.."
while pgrep -f "mlx_lm lora -c data/sft4/e13.yaml" >/dev/null; do sleep 60; done
[[ -f adapters/e13/0001200_adapters.safetensors ]] || { echo "E13 training failed early; see bench/e13/train.log"; exit 1; }
EV() { nice -n 5 .venv/bin/python scripts/eval_v4.py "$@" --chunked --suites data/sft4; }
EV models/qwen35-0.8b-kai-v3 --prompt v2 --split dev --json bench/e13/dev_baseline.json > bench/e13/dev_baseline.txt 2>&1
for step in 0001200 0002400 0003000; do
  [[ -f adapters/e13/${step}_adapters.safetensors ]] || continue
  d=adapters/e13-eval-$step; mkdir -p $d; cp adapters/e13/adapter_config.json $d/; cp adapters/e13/${step}_adapters.safetensors $d/adapters.safetensors
  EV mlx-community/Qwen3.5-0.8B-4bit --adapter $d --prompt v3 --split dev --json bench/e13/dev_$step.json > bench/e13/dev_$step.txt 2>&1
done
best=$(.venv/bin/python -c "
import json,os
c={s:json.load(open(f'bench/e13/dev_{s}.json'))['clips']['ALL']['wer'] for s in ['0001200','0002400','0003000'] if os.path.exists(f'bench/e13/dev_{s}.json')}
print(min(c,key=c.get))")
echo $best > bench/e13/best_step.txt
EV mlx-community/Qwen3.5-0.8B-4bit --adapter adapters/e13-eval-$best --prompt v3 --split test --json bench/e13/test_best.json > bench/e13/test_best.txt 2>&1
EV models/qwen35-0.8b-kai-v3 --prompt v2 --split test --json bench/e13/test_baseline.json > bench/e13/test_baseline.txt 2>&1
echo "E13 complete, best dev checkpoint: $best"
