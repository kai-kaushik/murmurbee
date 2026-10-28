#!/bin/zsh
# E12 overnight: train, score checkpoints 600/1200/1500 on dev, then the best one and the baseline on test.
cd "${0:A:h}/.."
mkdir -p bench/e12
nice -n 10 .venv/bin/python -m mlx_lm lora -c data/sft3/e12.yaml > bench/e12/train.log 2>>bench/stderr.log
if [[ ! -f adapters/e12/0001200_adapters.safetensors ]]; then
  echo "E12 training failed before the first scored checkpoint; see bench/e12/train.log"; exit 1
fi
for step in 0001200 0002400 0003000; do
  [[ -f adapters/e12/${step}_adapters.safetensors ]] || continue
  d=adapters/e12-eval-$step; mkdir -p $d; cp adapters/e12/adapter_config.json $d/; cp adapters/e12/${step}_adapters.safetensors $d/adapters.safetensors
  .venv/bin/python scripts/eval_v3.py mlx-community/Qwen3.5-0.8B-4bit --adapter $d --split dev --json bench/e12/dev_$step.json > bench/e12/dev_$step.txt 2>>bench/stderr.log
done
[[ -f bench/e12/dev_baseline.json ]] || .venv/bin/python scripts/eval_v3.py mlx-community/Qwen3.5-0.8B-4bit --adapter adapters/e12-start --split dev --json bench/e12/dev_baseline.json > bench/e12/dev_baseline.txt 2>>bench/stderr.log
best=$(.venv/bin/python -c "
import json
import os
c={s:json.load(open(f'bench/e12/dev_{s}.json'))['clips']['ALL']['wer'] for s in ['0001200','0002400','0003000'] if os.path.exists(f'bench/e12/dev_{s}.json')}
print(min(c,key=c.get))")
echo $best > bench/e12/best_step.txt
.venv/bin/python scripts/eval_v3.py mlx-community/Qwen3.5-0.8B-4bit --adapter adapters/e12-eval-$best --split test --json bench/e12/test_best.json > bench/e12/test_best.txt 2>>bench/stderr.log
[[ -f bench/e12/test_baseline.json ]] || .venv/bin/python scripts/eval_v3.py mlx-community/Qwen3.5-0.8B-4bit --adapter adapters/e12-start --split test --json bench/e12/test_baseline.json > bench/e12/test_baseline.txt 2>>bench/stderr.log
echo "E12 complete, best dev checkpoint: $best"
