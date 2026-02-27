# Cleaner Eval

Offline evaluation harness for complex speech-cleaning quality:
- filler/repetition cleanup
- semantic faithfulness
- logic coherence
- entity retention (time/number/place/medicine)

## Files
- `run_cleaner_eval.py`: evaluation entrypoint
- `judge_prompt.md`: judge rubric and JSON schema
- `cases.zh-CN.synthetic.jsonl`: Mandarin synthetic cases
- `cases.yue.synthetic.jsonl`: Cantonese synthetic cases

## Quick smoke (no API key)
```bash
python3 scripts/eval/run_cleaner_eval.py \
  --judge-provider heuristic \
  --force-cleaner-provider noop \
  --yue-mode both \
  --out-dir build/eval/cleaner-smoke \
  --verbose
```

## OpenAI judge + OpenAI force-cleaner
```bash
export OPENAI_API_KEY=...
python3 scripts/eval/run_cleaner_eval.py \
  --judge-provider openai \
  --judge-model gpt-4.1-mini \
  --force-cleaner-provider openai \
  --force-cleaner-model gpt-4.1-mini \
  --yue-mode both \
  --out-dir build/eval/cleaner-openai \
  --verbose
```

## Local MLX force-cleaner + OpenAI judge
```bash
export OPENAI_API_KEY=...
python3 scripts/eval/run_cleaner_eval.py \
  --judge-provider openai \
  --judge-model gpt-4.1-mini \
  --force-cleaner-provider local-mlx \
  --force-cleaner-model-dir models/qwen2.5-0.5b-4bit \
  --yue-mode both \
  --out-dir build/eval/cleaner-localmlx \
  --verbose
```

If `local-mlx` is missing runtime deps, install first:
```bash
pip install mlx-lm
```

By default, force-cleaner failures are fail-fast. If you need to inspect partial outputs:
```bash
python3 scripts/eval/run_cleaner_eval.py ... --allow-cleaner-errors
```

## Outputs
- `cleaner_outputs.jsonl`
- `judge_scores.jsonl`
- `summary.json`
- `summary.zh-CN.json`
- `summary.yue.skip.json`
- `summary.yue.force.json`
- `summary.md`
