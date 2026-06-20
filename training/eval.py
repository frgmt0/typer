#!/usr/bin/env python3
"""Benchmark a candidate GGUF against held-out completions, the way the app uses it.

This drives the real `typer-llama-server` over its JSONL stdin/stdout protocol (the
same one LlamaClient.swift speaks), so what we measure is exactly the app's behavior:
streaming partials, the confidence number, word-limited continuations.

For each held-out example {"prompt", "completion"} we send the prompt as `context`,
read the streamed response, and score the final suggestion against the gold
continuation:

  first_word     did the suggestion's first word match the gold's first word
  matched_words  how many leading words matched (the "type-through" length)
  shown          would the confidence gate have shown it (conf >= --min-confidence)
  latency_ms     request -> final suggestion
  ttfp_ms        request -> first streamed partial (the "feels instant" number)

Reports per-category and overall, with p50/p90 latency. This is the go/no-go meter
when deciding whether a trained model can replace the current one.

Stdlib only. Build the server first (scripts/build.sh) or point --server at it.
Run with `uv run training/eval.py --model path/to/model.gguf --data training/data/sft.jsonl`.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_SERVER = Path.home() / ".local" / "share" / "typer" / "typer-llama-server"


def first_word(s: str) -> str:
    s = s.strip()
    return s.split()[0].lower() if s.split() else ""


def matched_words(pred: str, gold: str) -> int:
    p = pred.strip().lower().split()
    g = gold.strip().lower().split()
    n = 0
    for a, b in zip(p, g):
        if a == b:
            n += 1
        else:
            break
    return n


class Server:
    """A persistent typer-llama-server child, one request at a time (like the app)."""

    def __init__(self, server: Path, model: Path):
        self.proc = subprocess.Popen(
            [str(server), "--model-path", str(model)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            bufsize=1, text=True, encoding="utf-8", errors="replace",
        )

    def request(self, context: str, max_words: int, timeout: float = 15.0, mode: str | None = None):
        """Send one completion request; return (final_text, conf, latency_ms, ttfp_ms).

        mode="raw" hits the server's harness-free greedy path (eval_compare.py's baseline);
        the default (None) is the full TYPER harness the app uses.
        """
        payload = {"task": "complete", "context": context, "max_words": max_words, "lexicon": ""}
        if mode:
            payload["mode"] = mode
        req = json.dumps(payload)
        assert self.proc.stdin and self.proc.stdout
        t0 = time.monotonic()
        self.proc.stdin.write(req + "\n")
        self.proc.stdin.flush()
        ttfp = None
        deadline = t0 + timeout
        while time.monotonic() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                break
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "p" in obj and obj["p"] is not None:          # streamed partial
                if ttfp is None:
                    ttfp = (time.monotonic() - t0) * 1000
                continue
            if obj.get("ok") is not None:                    # final line
                latency = (time.monotonic() - t0) * 1000
                sug = obj.get("suggestion") or {}
                text = (sug.get("text") or "") if sug else ""
                conf = (sug.get("conf") if sug else None) or 0.0
                if ttfp is None:
                    ttfp = latency
                return text, conf, latency, ttfp
        return "", 0.0, (time.monotonic() - t0) * 1000, ttfp or 0.0

    def close(self):
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
            self.proc.terminate()
            self.proc.wait(timeout=3)
        except Exception:
            self.proc.kill()


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = min(len(s) - 1, int(round((p / 100) * (len(s) - 1))))
    return s[k]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", type=Path, required=True, help="candidate .gguf")
    ap.add_argument("--data", type=Path, required=True, help="held-out jsonl {prompt, completion}")
    ap.add_argument("--server", type=Path, default=DEFAULT_SERVER)
    ap.add_argument("--max-words", type=int, default=7)
    ap.add_argument("--min-confidence", type=float, default=0.22)
    ap.add_argument("--limit", type=int, default=500, help="max examples to score")
    ap.add_argument("--json", action="store_true",
                    help="print one machine-readable metrics line (for the retrain promote-gate)")
    ap.add_argument("--calib-out", type=Path, default=None,
                    help="also write {confidence, good} per example here, for calibrate_gate.py "
                         "(good = the model's first word matched gold) — offline gate calibration")
    args = ap.parse_args()

    if not args.server.exists():
        print(f"server not found: {args.server}\nBuild it with scripts/build.sh, or pass --server.", file=sys.stderr)
        return 2
    if not args.model.exists():
        print(f"model not found: {args.model}", file=sys.stderr)
        return 2

    rows = []
    for line in args.data.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("prompt") and obj.get("completion"):
            rows.append(obj)
        if len(rows) >= args.limit:
            break
    if not rows:
        print("no examples in --data", file=sys.stderr)
        return 2

    srv = Server(args.server, args.model)
    n = 0
    fw_hits = 0
    matched_total = 0
    gold_words_total = 0
    shown = 0
    latencies: list[float] = []
    ttfps: list[float] = []
    calib: list[dict] = []
    try:
        for r in rows:
            text, conf, latency, ttfp = srv.request(r["prompt"], args.max_words)
            n += 1
            latencies.append(latency)
            ttfps.append(ttfp)
            gold = r["completion"]
            gw = len(gold.split())
            gold_words_total += gw
            mw = matched_words(text, gold)
            matched_total += mw
            good = bool(first_word(text)) and first_word(text) == first_word(gold)
            if good:
                fw_hits += 1
            if conf >= args.min_confidence and text.strip():
                shown += 1
            if args.calib_out is not None:
                calib.append({"confidence": float(conf), "good": good})
            if n % 50 == 0:
                print(f"  …{n}/{len(rows)}", file=sys.stderr)
    finally:
        srv.close()

    if args.calib_out is not None:
        with args.calib_out.open("w", encoding="utf-8") as f:
            for c in calib:
                f.write(json.dumps(c) + "\n")
        print(f"wrote {len(calib)} calibration rows -> {args.calib_out}", file=sys.stderr)

    if args.json:
        # One line, parseable by train.sh's promote-gate. first_word_acc is the headline
        # quality metric; matched_avg is the type-through proxy.
        print(json.dumps({
            "model": args.model.name, "n": n,
            "first_word_acc": round(fw_hits / n, 4),
            "matched_avg": round(matched_total / n, 4),
            "shown_rate": round(shown / n, 4),
            "latency_p50": round(pct(latencies, 50), 1),
            "ttfp_p50": round(pct(ttfps, 50), 1),
        }))
        return 0

    print("\n=== eval ===")
    print(f"model:           {args.model.name}")
    print(f"examples:        {n}")
    print(f"first-word acc:  {fw_hits / n:.3f}")
    print(f"matched words:   {matched_total / n:.2f} avg  ({matched_total}/{gold_words_total} of gold)")
    print(f"shown (conf≥{args.min_confidence}): {shown / n:.3f}")
    print(f"latency ms:      p50 {pct(latencies, 50):.0f}  p90 {pct(latencies, 90):.0f}")
    print(f"time-to-1st ms:  p50 {pct(ttfps, 50):.0f}  p90 {pct(ttfps, 90):.0f}")
    print("\nfirst-word acc & matched-words are the next-chunk quality proxy; ttfp p50 is")
    print("the 'feels instant' number (target <100ms). Compare a candidate to Gemma here.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
