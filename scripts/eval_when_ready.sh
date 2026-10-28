#!/bin/zsh
# Wait for the resumed run's next checkpoint, then compare: v1 (current app model), v2 step 600 (first run),
# and v2 resumed checkpoint. Results -> bench/eval_round3.txt
cd "${0:A:h}/.."
CK=adapters/qwen35-0.8b-kai-v2/0000600_adapters.safetensors
START=$(stat -f %m $CK)
until [[ $(stat -f %m $CK) -gt $START ]]; do sleep 30; done
sleep 10
mkdir -p adapters/eval-first600 adapters/eval-resumed600
for d in eval-first600 eval-resumed600; do cp adapters/qwen35-0.8b-kai-v2/adapter_config.json adapters/$d/; done
cp adapters/qwen35-0.8b-kai-v2-step600.safetensors adapters/eval-first600/adapters.safetensors
cp $CK adapters/eval-resumed600/adapters.safetensors
{
  echo "== v1 (current app model)"; .venv/bin/python scripts/eval_v2.py models/qwen35-0.8b-kai-v1 --prompt v1
  echo "== v1 on v2 structure set (v2 prompt)"; .venv/bin/python scripts/eval_v2.py models/qwen35-0.8b-kai-v1 --prompt v2 | sed -n '/STRUCTURE/,$p'
  echo "== v2 first run, step 600"; .venv/bin/python scripts/eval_v2.py mlx-community/Qwen3.5-0.8B-4bit --adapter adapters/eval-first600
  echo "== v2 resumed (with self-corrections), checkpoint"; .venv/bin/python scripts/eval_v2.py mlx-community/Qwen3.5-0.8B-4bit --adapter adapters/eval-resumed600
} > bench/eval_round3.txt 2>>bench/stderr.log
echo done >> bench/eval_round3.txt
