#!/usr/bin/env python3
"""Mine REAL human golds from the local Typer capture, privacy-cleaned, never leaving the Mac unscreened.

`~/Library/Application Support/typer/training.jsonl` records, per shown suggestion, the context you
typed and how you responded. The rows you ACCEPTED — Tab, backtick, or typed-through — are genuine
human continuations: the highest-fidelity data there is, because it's literally you. This extracts
them as golds in the collect_human_data.py format.

PRIVACY: capture already screens secrets at write time, but this adds a hard second pass — any row
whose context or continuation matches an email, URL, IP, phone, long digit run, file path, @handle,
or key-like token is DROPPED entirely (not redacted). Run with --review to eyeball a sample before
anything is used. Nothing is sent anywhere by this script; it only reads local capture and writes a
local golds file you can inspect.

QUALITY: rows whose text carries a control, private-use or replacement character are dropped too.
Those never come from a human typing prose — they come from arrow keys, OCR'd UI chrome and font
private-glyph ranges leaking into the captured context — and training on them teaches the model to
emit them back. Same rule set as the helper's strip_disallowed (scripts/llama_server_text.h).

Invisible FORMAT characters (Cf, plus the BOM) are a different matter and are STRIPPED, not a
reason to drop: a BOM in front of a pasted line is the single commonest pollutant in real capture
(897 of 14.5k rows in one sample) and the prose around it is perfectly good human writing. Dropping
those rows threw away 6% of the corpus for an invisible byte. Two exemptions, same as the helper:
U+200D ZERO WIDTH JOINER and the U+E0020-U+E007F tag block, which hold emoji sequences and regional
flags together.

  uv run training/mine_capture.py --review
  uv run training/mine_capture.py --selftest
"""
from __future__ import annotations

import argparse
import json
import re
import unicodedata
from pathlib import Path

PRIVATE = [
    re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"),                 # email
    re.compile(r"https?://\S+|\bwww\.\S+"),                  # url
    re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"),              # ip
    re.compile(r"\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b"),        # phone
    re.compile(r"\b\d{5,}\b"),                               # long digit run (ids, cards, codes)
    re.compile(r"(?:^|\s)[~/][\w./-]{3,}"),                  # file path
    re.compile(r"(?:^|\s)@\w{2,}"),                          # @handle / mention
    re.compile(r"\b[A-Za-z0-9_-]{24,}\b"),                   # key/token-like long string
]


def looks_private(s: str) -> bool:
    return any(p.search(s) for p in PRIVATE)


def has_disallowed(s: str) -> bool:
    """True if `s` holds a character that can't be part of typed prose.

    Unicode general categories do the work: Cc = C0/C1 controls (minus tab/newline/return,
    which are real text), Co = private use (U+E000-U+F8FF and planes 15-16 — Apple's  ,
    Nerd Font glyphs, anything an app paints with a private codepoint), Cs = surrogate.
    Plus U+FFFD, which means information was already lost upstream. Cf is NOT included —
    see strip_invisibles: those are cleaned out of the row, not grounds for dropping it.
    """
    for ch in s:
        if ch in "\t\n\r":
            continue
        if ch == "�" or unicodedata.category(ch) in ("Cc", "Co", "Cs"):
            return True
    return False


def is_invisible(ch: str) -> bool:
    """True for a format character that carries no signal and should simply go.

    Cf is the category: soft hyphen, zero-width space, bidi marks and overrides, word
    joiner, and U+FEFF — the byte-order mark that leads most pasted text. Two exemptions,
    matching scripts/llama_server_text.h exactly:
      * U+200D ZERO WIDTH JOINER glues multi-person and profession emoji together.
      * U+E0020-U+E007F, the TAG block, spells out regional flags (England, Scotland,
        Wales) after a U+1F3F4; stripping tags would shred them.
    """
    if ch == "‍" or "\U000e0020" <= ch <= "\U000e007f":
        return False
    return unicodedata.category(ch) == "Cf"


def strip_invisibles(s: str) -> str:
    """`s` with every invisible format character removed. Clean text is returned as-is."""
    return "".join(ch for ch in s if not is_invisible(ch))


def norm_completion(context: str, text: str) -> str:
    t = (text or "").strip()
    if not t:
        return ""
    if context and not context[-1].isspace() and not t[0].isspace():
        t = " " + t
    return t


def mine(lines: list[str], max_ctx_chars: int) -> tuple[list[dict], dict]:
    """Turn capture JSONL lines into golds. Returns (golds, drop counts by reason)."""
    kept: list[dict] = []
    stats = {"private": 0, "empty": 0, "control": 0, "invisible": 0}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = r.get("accept_kind")
        wa = r.get("words_accepted") or 0
        if not (r.get("accepted") and wa > 0 and kind in {"tab", "backtick", "typethrough"}):
            continue
        raw_ctx = (r.get("context") or "").rstrip()
        raw_sug = (r.get("suggestion") or "").strip()
        # Invisibles come out first, before anything is measured or matched: a BOM in front
        # of a pasted line is not a reason to lose the line, and leaving it in would also
        # let it split a token the privacy regexes are looking for.
        ctx = strip_invisibles(raw_ctx)
        sug = strip_invisibles(raw_sug)
        if ctx != raw_ctx or sug != raw_sug:
            stats["invisible"] += 1
        # The accepted continuation = the first `words_accepted` words of the shown suggestion.
        gold = " ".join(sug.split()[:wa]).strip()
        if not ctx or not gold or not any(c.isalnum() for c in gold):
            stats["empty"] += 1
            continue
        if looks_private(ctx) or looks_private(gold):
            stats["private"] += 1
            continue
        # Polluted capture: an arrow key, a private-use glyph or a replacement char in
        # the context/suggestion means this row is transport noise, not human writing.
        if has_disallowed(ctx) or has_disallowed(sug) or has_disallowed(gold):
            stats["control"] += 1
            continue
        if len(ctx) > max_ctx_chars:
            ctx = ctx[-max_ctx_chars:]
        app = r.get("app_category", "other") or "other"
        kept.append({"prompt": f"Writing app: {app}\n\n{ctx}",
                     "completion": norm_completion(ctx, gold),
                     "app": app, "register": app, "source": f"capture:{kind}"})
    return kept, stats


def selftest() -> int:
    """Assertions over the screens + the row miner. No files, no network."""
    assert has_disallowed("arrow\u001ckey")
    assert has_disallowed("del\u007f")
    assert has_disallowed("c1\u0085here")
    assert has_disallowed("applelogo")
    assert has_disallowed("plane15\U000f0000")
    assert has_disallowed("lost�char")
    assert not has_disallowed("")
    assert not has_disallowed("plain prose, with punctuation!")
    assert not has_disallowed("tabs\tand\nnewlines\rsurvive")
    assert not has_disallowed("café — naïve 日本語")
    assert not has_disallowed("👨‍👩‍👧 family and ❤️")   # ZWJ + VS16 kept
    # Invisibles are stripped, not disallowed — the row survives, minus the byte.
    assert not has_disallowed("﻿bom at the front")
    assert not has_disallowed("zero​width")
    assert strip_invisibles("﻿bom at the front") == "bom at the front"
    assert strip_invisibles("zero​width‎ mark­ soft") == "zerowidth mark soft"
    assert strip_invisibles("plain prose, with punctuation!") == "plain prose, with punctuation!"
    assert strip_invisibles("café — naïve 日本語") == "café — naïve 日本語"
    assert strip_invisibles("👨‍👩‍👧 family and ❤️") == "👨‍👩‍👧 family and ❤️"   # ZWJ kept
    assert strip_invisibles("\U0001f3f4\U000e0067\U000e0062\U000e0065\U000e006e\U000e0067\U000e007f") \
        == "\U0001f3f4\U000e0067\U000e0062\U000e0065\U000e006e\U000e0067\U000e007f"  # England flag

    assert norm_completion("hello", "there") == " there"
    assert norm_completion("hello ", "there") == "there"
    assert norm_completion("hello", "") == ""

    row = {"accepted": True, "accept_kind": "tab", "words_accepted": 2,
           "context": "I was walking to", "suggestion": "the store today",
           "app_category": "chat"}

    def line(**over) -> str:
        return json.dumps({**row, **over}, ensure_ascii=False)

    golds, stats = mine([line(),
                         line(context="I was\u001c walking to"),          # control in context
                         line(suggestion="the store� today"),        # replacement char in suggestion
                         line(context="mail me at a@b.com now"),          # private
                         line(suggestion="   "),                          # empty gold
                         line(context="﻿I was walking to"),          # BOM: cleaned, row KEPT
                         line(suggestion="the sto​re today"),        # ZWSP: cleaned, row KEPT
                         line(accepted=False, accept_kind="none")], 200)  # not accepted
    assert len(golds) == 3, golds
    assert golds[0]["completion"] == " the store", golds[0]
    # The cleaned rows are real golds, identical to the unpolluted one.
    assert golds[1]["prompt"].endswith("I was walking to"), golds[1]
    assert golds[2]["completion"] == " the store", golds[2]
    assert stats == {"private": 1, "empty": 1, "control": 2, "invisible": 2}, stats

    # A long context is trimmed to its tail, and emoji/accents survive the whole path.
    golds, _ = mine([line(context="one two three " * 30 + "café 👩‍💻", suggestion="works fine")], 40)
    assert golds[0]["prompt"].endswith("café 👩‍💻"), golds[0]
    assert len(golds[0]["prompt"].split("\n\n", 1)[-1]) == 40

    print("selftest: OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--capture", type=Path,
                    default=Path.home() / "Library/Application Support/typer/training.jsonl")
    ap.add_argument("--out", type=Path, default=Path("data/capture_golds.jsonl"))
    ap.add_argument("--max-ctx-chars", type=int, default=200, help="trim context to its tail")
    ap.add_argument("--review", action="store_true", help="print a sample + stats, write nothing")
    ap.add_argument("--selftest", action="store_true", help="run the built-in screen tests and exit")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if not args.capture.exists():
        print(f"no capture at {args.capture}"); return 0

    kept, stats = mine(args.capture.read_text(encoding="utf-8", errors="ignore").splitlines(),
                       args.max_ctx_chars)

    print(f"accepted rows kept: {len(kept)}  ·  dropped {stats['private']} (private) + "
          f"{stats['empty']} (empty) + {stats['control']} (control/private-use chars)  ·  "
          f"stripped invisibles in {stats['invisible']} rows")
    if args.review:
        print("\nsample (privacy-cleaned) — context tail -> your continuation:")
        for g in kept[:12]:
            ctx = g["prompt"].split("\n\n", 1)[-1]
            print(f"  [{g['register']}] …{ctx[-44:]!r} -> {g['completion']!r}")
        print("\n(--review: nothing written. re-run without --review to save.)")
        return 0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as f:
        for g in kept:
            f.write(json.dumps(g, ensure_ascii=False) + "\n")
    print(f"wrote {len(kept)} capture golds -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
