# typer-1 v1 — `typer1-f16.gguf`

The first full fine-tune of **Qwen3-0.6B-Base** on the autocomplete SFT set (`training/data/sft.jsonl`,
~212k prefix→5-7-word continuation pairs across chat/docs/web/code), f16 GGUF (~1.2 GB).

**Hosted on HuggingFace** (too big for in-repo LFS): <https://huggingface.co/milosa/typer-1-v1>

```bash
# fetch the model
hf download milosa/typer-1-v1 typer1-f16.gguf --local-dir models/
# or: curl -L https://huggingface.co/milosa/typer-1-v1/resolve/main/typer1-f16.gguf -o models/typer1-f16.gguf

# evaluate it the way the app runs it (raw context, greedy default sampler)
uv run training/eval_compare.py --harness models/typer1-f16.gguf            # harness vs raw
uv run training/eval.py --model models/typer1-f16.gguf --data training/data/typed_eval.jsonl
```

## Eval (typed-content set, 180 mid-utterance examples, first-word accuracy)

| metric | raw greedy | TYPER harness |
|---|---|---|
| first-word | 36.1% | **38.9%** |
| matched-words | 0.55 | 0.58 |

By register (harness): prompt 50% · email 43% · search 43% · code 41% · chat 38% · notes 33% · shell 20%.

Context: v1 beat a data-reweighted variant (v2), a larger SmolLM2-1.7B fine-tune, and the original
Gemma-4-E2B baseline (22.2%) by +14 pts on this set. See `training/eval_compare.py` for the harness.
