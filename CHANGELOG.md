# Changelog

Typer is in **alpha** and not yet versioned. Entries are newest-first, led by the
commit they landed in. Website: [typr.frgmt.xyz](https://typr.frgmt.xyz).

## Arrow keys were being typed into the prompt

An investigation into "the suggestions are bad" found the cause upstream of the model. The event
tap filtered a handful of keys by name — Tab, backtick, Esc, Backspace, Return, ⌘/⌃/⌥ chords — and
handed **everything else with a non-empty character payload** to the typing path. On this machine
that meant the arrow keys arrived as U+001C–U+001F, Home/End/PgUp/PgDn as U+0001/0004/000B/000C,
forward-delete as U+007F, every F-key as U+0010, Help as U+0005, keypad Enter as U+0003 and keypad
Clear as U+001B. All of it was appended to the typed buffer — which *is* the prompt whenever an app
won't expose its text over Accessibility — then written into the style memory, the vocabulary
lexicon and the training corpus, and treated as "the user typed, generate again".

- **Keys are classified by keycode now (`InputSanitizer.swift` new, `TyperApp+EventTap.swift`).**
  A keycode is layout-independent — 123 is Left Arrow on Dvorak, AZERTY and a Czech layout alike —
  while the produced character is precisely the thing that lies. Every key is sorted into text /
  navigation / edit / backspace / submit / dismiss / accept / command / ignore before anything
  reaches the buffer, and a key we believe is a text key still has to prove it produced text.
  `appendToBuffer` screens again on the way in, so no future caller can reopen the hole.
- **Caret navigation is no longer recorded as a rejection.** An arrow key while a suggestion was up
  resolved it as an explicit "no": reward 0 to the model race, a negative to the adaptive feedback
  layer, an `accepted: false` row in the training log. That dragged the measured acceptance rate to
  ~0.12, which raised the confidence gate, clamped suggestions to three words and left both router
  arms at a ~0.02 mean reward. Moving the cursor is not an opinion. A suggestion's outcome is now
  resolved from exactly three things: an explicit accept, typing that diverges from it, or Esc.
- **The buffer re-syncs when the caret moves.** It only ever did so on a mouse click and ⌘V/⌘X/⌘Z,
  so ←, Home, ⌘A, ⌘←, ⌃A/⌃E/⌃K, ⌘⇧Z and every other chord left the buffer describing text that was
  no longer where the caret was. Any unmodelled key now takes the ghost down immediately and
  schedules **one** debounced Accessibility re-sync after the key settles — a held ← costs one read,
  not thirty. `AXSelectedTextChanged` notifications that are not attributable to our own keystroke,
  our own injection or a suggestion we painted in the last 400 ms do the same, which catches Find,
  menu commands and apps that move the insertion point programmatically; one that arrives while a
  generation is actually in the helper is parked and acted on when the request returns, instead of
  being dropped. A short list of chords known to touch neither the caret nor the text (⌘C, ⌘S, ⌘⇥,
  ⌘space, ⌘Q/W/M/H, ⌘,, ⌘P, ⌘=/−/0, and the ⌘B/⌘I/⌘U formatting toggles) skips the read entirely.
- **Editing mid-text gives you a suggestion again.** The re-sync deliberately waits for a typing
  pause, and when it finally ran it cancelled the generation, cleared the ghost and scheduled
  nothing — so after *any* caret move there was no suggestion at the first pause, which is most of
  what editing an existing sentence consists of. A re-sync the user has already typed past is now a
  reconciliation rather than an invalidation: the typing that followed the arrow key re-established
  where the caret is, so a suggestion built on it stays up (the host's own text is checked against
  what we watched being typed, and the full teardown still happens if they disagree), and a
  completion is generated once the buffer is correct. Until it is, only the characters typed since
  the caret moved are used as prompt context — never those glued onto text from the old position.
- **A re-sync no longer wipes the buffer in the apps that need it most.** "Accessibility answered
  with nothing" and "Accessibility could not answer" were the same branch, and both threw the whole
  buffer away. In a terminal or an Electron shell with no exposed text — exactly where the keystroke
  buffer *is* the prompt — every arrow key therefore discarded it 150 ms later. The keystrokes since
  the caret moved are kept (they are known-good text immediately before the caret); only the part we
  genuinely no longer know about is dropped.
- **⌥ is a text modifier, not a command modifier.** It was lumped in with ⌘ and ⌃, so every é, –, —,
  … and " " reached the document but never the buffer, and the prompt silently disagreed with what
  was on screen.
- **Deletes that aren't one character.** ⌫ removed exactly one character from the buffer even for
  ⌥⌫ (a word), ⌘⌫ (a line) or ⌫ over a selection, and it was handled *before* the modifier check so
  the modifier never mattered. Those now go down the re-sync path; forward-delete removes the
  character *after* the caret, so it no longer appends U+007F; keypad Enter takes the Return path
  and keypad Clear the Esc path.
- **Auto-repeat is read at last.** A held key's `.keyboardEventAutorepeat` flag was never looked at,
  so a leaned-on letter entered the vocabulary as "wwwww". Repeats still reach the buffer — a held
  key really does type — but are excluded from the lexicon, and repeated navigation keys collapse
  into the single debounced re-sync.
- **typer no longer learns from itself.** Accepting a suggestion appended the **model's** text to
  the buffer without advancing the learning watermark, so the next flush taught the lexicon and the
  style memory typer's own output as the user's vocabulary and voice — and lexicon words get a
  logit boost on every later generation, a closed loop. Inserted text is now tracked as an
  unlearnable span: the lexicon skips it, and the style memory records only the runs of genuinely
  user-written text around it. If the buffer is ever rewritten by a path that doesn't keep this
  bookkeeping, nothing is learned at all rather than guessed at.
- **…and it no longer learns from other people.** A caret re-sync fills the buffer with up to 500
  characters of whatever the host app has in the field — a received email, a shared document, a page
  of someone else's prose — and the style memory had no watermark, so it re-recorded the *whole*
  buffer on every flush. Every arrow key and every click could therefore file a stranger's writing
  in `style.txt` as the user's voice. Re-synced text is now marked unlearnable in its own right and
  excluded from the style memory as well as the vocabulary, and the style memory has the same
  per-app watermark the lexicon has, so a paragraph is offered once rather than on every flush.
  "Reset all data" clears that bookkeeping too: it used to leave the span records behind with the
  buffers gone, which made every later flush unattributable and silently switched learning off for
  good.
- **Personalization strength 0 now means off.** The code comment said strength 0 yielded an empty
  list; it actually sent 48 words, and the shipped strength of 0.35 sent 54 words at a **+1.2 logit**
  boost. Under the helper's greedy decoding that is not the "gentle tie-break" the design calls for
  — a boost that size simply overrides the model's own ranking. The slider now scales how many of
  your words are sent and how much style sample rides along; the per-word boost is fixed at the
  evaluated **+0.5** ceiling (the helper's own default, `PersonalizationBias.maxBoost`, and the
  figure `docs/autocomplete-model.md` documents), and strength 0 sends nothing at all.
- **Suggestions that can't be shown, aren't.** A suggestion carrying a control or private-use scalar
  is dropped outright, and the text-after-the-caret echo guard now works in Accessibility-hostile
  apps too (it was silently inert wherever the keystroke buffer beat AX for the prompt).
- **Esc means stop.** Dismissing a suggestion now also cancels the generation behind it. A request
  already in the helper used to land a fifth of a second later and put the dismissed text straight
  back on screen — with its outcome recorded a second time, against a suggestion the user had
  already said no to. A dismissed suggestion is also remembered, so it is not re-shown while the
  context is unchanged: greedy decoding regenerates it character for character. That covers Esc, and
  typing past a suggestion and then backspacing back to where it was shown. It deliberately does
  *not* keep suppressing anything once you have typed on — by then the context has moved and the
  next suggestion is genuinely a different one. The match tolerates a prefix either way, because a
  suggestion dismissed mid-stream is only the part that had arrived.
- **Training rows record the context the model actually saw.** They logged the raw keystroke buffer
  even when the generation had been built from Accessibility text, so a large share of the corpus
  paired a suggestion with a context that never produced it. The schema version is read from
  `TrainingLog.schemaVersion` instead of a literal at each write site.

### The helper stopped eating its own escape codes

`scripts/llama_server.cpp`'s string logic now lives in `scripts/llama_server_text.h`, free of
llama.cpp, so it can be compiled and tested with clang++ alone (`scripts/run_helper_tests.sh`).

- **The JSON unescaper was incomplete.** It understood `\n \t \r \" \\` and fell through to a raw
  copy for everything else — but Swift's `JSONEncoder` escapes every C0 control as `\u001c` and `/`
  as `\/`, so a stray arrow key in the context reached the model as the **literal ASCII text**
  `u001c`, and greedy decoding continued it forever. The whole grammar is implemented now,
  `\uXXXX` and surrogate pairs included, with malformed input dropped rather than substituted.
- **A scalar screen on both sides of the model.** Control, C1, private-use and U+FFFD scalars and
  invalid UTF-8 are stripped from the prompt and, mid-stream, end the generation rather than flash
  in the ghost text. A truncated multi-byte character at the token budget is trimmed first, so a
  split emoji isn't mistaken for the model misbehaving.
- **A loop detector that survives space-free garbage.** The old repeated-word check was
  space-delimited and structurally could not see `u001cu001cu001c…`, which is one "word". The new
  one catches a 2–8 byte unit repeated back to back — four times over nine bytes for a short unit,
  three times over twelve for a longer one — while leaving "banana", "Mississippi", "hahaha",
  "$1,000,000,000" and runs of repeated emoji alone. URLs, paths and hex dumps repeat short units
  for structural reasons and are exempted, but narrowly: the structure has to be inside the repeated
  unit itself (one `/` anywhere in a space-free string used to switch the detector off for all of
  it, so `foo/loooploooploooploop` sailed through), a hex exemption needs the repeated run to be hex
  digits inside an `0x…` token, and six identical repetitions are never exempt whatever they are
  made of.

### Stores that validate, and a one-time repair of the ones that didn't

- **Every write path is gated (`TextSanitizer.swift` new).** One shared scalar policy decides what
  may be learned from, persisted or sent to the model: everything passes except C0/C1 controls
  (bar tab/newline/CR), private use, U+FFFD and noncharacters. Invisible *formatting* — U+FEFF and
  the rest of the Cf category, minus the two ranges that hold real emoji together (the zero-width
  joiner, and the tag block a subdivision flag like 🏴󠁧󠁢󠁥󠁮󠁧󠁿 is built from) — is **stripped** rather
  than used as grounds to throw a row away: it arrives from applications' Accessibility text, not
  from a keyboard, and on the real corpus 897 of 14,503 training rows and 17 style lines contained
  nothing disallowed except invisibles. Dropping them would have cost 6% of the corpus to delete
  characters nobody can see.
- **A one-time migration repairs what is already on disk (`StoreMigration.swift` new).** It runs
  once, at launch, before any store is read. Every file is **backed up first** (never overwriting an
  existing backup) and rewritten through a sibling temp file, 0600 preserved; a store that needs no
  edits is neither backed up nor rewritten; the done-marker is only stamped once every store
  succeeded, so a partial run retries on the next launch instead of being silently skipped. On the
  author's own data: 420 training rows dropped and 897 repaired, 5 style lines dropped and 17
  repaired, 55 lexicon entries dropped. Rows that need no repair are written back byte-identical.
- **`feedback.json` and `router.json` are reset, not repaired.** They hold no text — they hold a
  verdict built from arrow keys counted as rejections, and there is no way to tell a real rejection
  from a cursor move after the fact. Both are backed up and removed; both loaders treat a missing
  file as "no history", which is exactly the state we want. They re-learn within a few hundred
  suggestions.
- **The log rotates (`Logging.swift`).** It was append-only and had reached 16 MB in the field. It
  now rotates at 8 MB, keeping one previous generation so a crash report still has the run before
  last — at most ~16 MB on disk, ever. Writes go through a single long-lived handle on a serial
  queue instead of an open/seek/write/close per call, several of which ran per keystroke.
- **Two more headless test suites.** `scripts/run_input_tests.sh` (214 checks) covers the keycode
  table with every modifier combination, the harmless-chord list, the rejected-suggestion match and
  the unlearnable-span bookkeeping; `scripts/run_store_tests.sh` (268 checks) covers the scalar
  policy, the word shape, `TrainingLog`'s write gate and streaming roll, and the migration end to
  end — including a run against a copy of a real store directory that reports counts only, never
  contents.

## One caret probe, no more massive text, and a ghost that hides instead of guessing

An investigation into "the ghost is in the wrong place" found 1,982 wrong-place fallbacks in a
single session: the caret pipeline could not fail. Every tier ended in a hardcoded point that the
overlay then clamped onto the main screen, so a failed probe always produced a confident placement
somewhere. That is gone. Placement is now one probe returning one value — or nothing, in which case
the ghost hides and the suggestion waits for a real fix.

- **One probe, one value (`CaretGeometry.swift` new, `TyperApp+Caret.swift`).** A single
  `resolveCaret()` returns a `CaretFix` (caret point, line height, font, colour, screen, element
  frame, which tier produced it) or `nil` — and `nil` means *do not show*. Everything downstream
  (ghost font, panel height, `ghostWidth`'s measuring font, the screenshot capture clip) reads that
  struct instead of going back to Accessibility, which took a placement from 10–50+ synchronous AX
  round-trips to about five. The `(400, 400)` last-resort point, the focused-element-frame tier and
  the clamp-onto-`NSScreen.main` rescue are all deleted.
- **No more massive text.** The ghost font is now bounded by the *measured* caret line, not by
  whatever point size the host's attributed string claims: an AX font is only believed when its own
  line box matches the line we measured, the final size can never exceed 1.35x the line, and the
  font cache is keyed by the **focused element** with a 30s TTL instead of by bundle id. Clicking a
  Notion H1 used to hand back a 48pt font that was then cached for the whole session and applied to
  every field in the app.
- **Garbage rects are rejected in AX space, before the flip.** The classic bogus AX answer is
  `(0, 0, w, h)`; the old guard ran *after* the top-left→bottom-left flip, by which point it looked
  like an ordinary rect near the top of the primary display — which is exactly where the ghost kept
  landing. Validation now runs pre-flip and also checks the rect against the focused element's own
  frame, a plausible line-height window (absolute, and relative to this element's known line), a
  per-probe width cap (a 300pt "caret" is a selection), and requires the flipped rect to sit wholly
  inside exactly one display. The width caps are relative to the rect's own height, which is only
  safe while the element frame is there to bound it — so when the frame is unknown they fall back to
  strict absolute ceilings, and the whole-line tier (whose cap is deliberately unbounded, and whose
  commonest wrong answer is "the entire text view") is not admissible without a frame at all.
- **A real ladder, and Chromium/Electron finally answer it.** Browsers and Electron shells get
  `AXManualAccessibility` set once per process — without it Chrome, Slack, Discord, VS Code and
  Notion expose no text geometry at all — and are probed marker-first; everything else is probed
  bounds-first. `AXBoundsForRange` is now at most three probes (collapsed caret → previous glyph's
  right edge → next glyph's left edge); the 40-step backward scan, which could fire 40 synchronous
  round-trips on the main thread, is gone. A non-collapsed selection is probed at its collapsed end
  instead of returning the selection rectangle. A new `AXInsertionPointLineNumber` /
  `AXRangeForLine` tier covers line ends and empty lines.
- **The ghost stays on the right monitor (`SuggestionOverlay.swift`, `GhostView.swift`).** The
  screen is chosen by the caret *point*, never by intersecting the up-to-760pt-wide ghost frame and
  never `NSScreen.main`; no screen owns the point means nothing is drawn. A ghost too wide for the
  room left is truncated rather than shifted left over the text you are typing, and the layer's
  contents scale now follows the display it lands on instead of being fixed at construction.
- **Staleness has a budget.** Typing through a suggestion extrapolates the cached caret forward for
  at most 600ms / 40 characters / zero line changes; past that the ghost hides until a fresh fix
  lands. The click anchor gets 20s / 80 characters and is dropped once the extrapolated advance
  approaches the field's right edge (soft wrap). Caret state is invalidated on focused-element
  change, app switch, scroll, mouse-down, **window move/resize**, **display-layout change** and
  **Space change** — the last three are new, and all of them previously left the ghost pinned to
  stale pixels.
- **Snappier.** All re-anchor requests (AX notifications, the 90/280ms timers, scroll, streaming
  partials) coalesce to at most one probe per ~16ms tick; the caret probe runs on a 25ms AX
  messaging budget (the rest of the app keeps 50ms); an app whose AX wedges twice in a row is put on
  the cheap tiers for 10 seconds; the window's web host is read once per focus session and only for
  browsers (it used to run five AX reads plus a freshly compiled `NSDataDetector` on *every*
  placement, in every app); and the display flip pivot is cached instead of re-enumerating screens.
- **A headless test suite (`scripts/caret_tests.swift`, `scripts/run_caret_tests.sh`).** The
  placement rules are pure functions of their arguments — screens and the flip pivot are passed in —
  so 180 table-driven checks cover the flip on negative-origin/above/below displays, every rejection
  case, the font clamp, multi-monitor screen selection, ghost clamping and the staleness budgets,
  with no window server or Accessibility grant required.

## Click-anchored caret in Electron/web, ~10x cheaper screenshots, no more phantom percentages

Three things that made suggestions feel off in non-native apps are fixed: the ghost now lines up
where you're actually typing in Electron/web fields, the screenshot/OCR paths cost a fraction of
what they did, and completions stop emitting bare percentages.

- **Click-to-anchor caret (`TyperApp+Caret.swift`, `+EventTap.swift`).** Apps like Slack, Discord
  and browser chat boxes expose no Accessibility caret, so the ghost used to drift off the cursor.
  A left-click *is* a caret placement, so we now record the click point and slide it right by the
  measured width of what you type — accurate inline placement with **zero** screenshots or OCR.
  This is the new default fallback (`click_caret_enabled = true`) and closes most of the
  native-vs-Electron gap. Bounded to a single line (a newline or a long burst since the click drops
  the anchor), and it yields immediately to the real AX caret whenever one is available.
- **Screenshot caret locator ~10x cheaper (`TyperApp+Context.swift`).** When the screenshot
  fallback *is* enabled, it no longer grabs the whole window: `captureFocusedWindow` takes an
  optional clip rect and captures only a few-line band around the caret (computed on the main
  thread from the focused element's bounds), OCR'd with Vision's `.fast` path. The full-window
  ambient OCR (screen context + topic capture) now captures at half resolution with a
  `minimumTextHeight` floor that skips tiny chrome — roughly a 4x Vision cost cut on those.
- **No more phantom percentages (`scripts/llama_server.cpp`).** The first suggestion in a fresh
  field was often "100%" or "90%" — UI chrome (zoom level, battery, progress) leaking in through
  screen context and getting continued. Fixed at three layers: a model-agnostic gate drops any
  completion that's a bare number or leads with a percentage (unless you're mid-number, so "5" →
  "0%" still works); a streaming guard kills a leading percentage before it can flash; and the OCR
  /AX context filters now reject numeric-only chrome lines instead of feeding them to the model.
- **On-screen context is now framing, not steering (`TyperApp+Context.swift`).** Background context
  is relabeled and trimmed so the model treats what's on screen as *consideration* (topic/tone),
  not as text to tailor the completion to — your live line stays the thing being continued.
- **Battery-aware caret end to end.** The default path needs no capture at all, the screenshot
  path captures a band instead of a screen, and ambient OCR runs at half res. A follow-up
  adversarial review also caught and fixed an off-main `NSScreen` read in the OCR caret path and a
  stranded-ghost case where a suppressed partial wasn't torn down.

## A typed-content eval, a greedy harness, and a Claude-distilled typer-1

We were grading typer-1 on prose and serving a sampler tuned for a model we no longer ship. Both
are fixed. A new eval measures the model on the registers people actually type in; a diagnostic
separated the model from its harness and found the harness was the bottleneck; and the small model
now distills from Claude instead of Gemma. The Claude-distilled student is live and taking ~60% of
traffic from the Gemma-distilled arm in the race.

- **Typed-content eval (`training/build_typed_eval.py`, `eval_compare.py`).** 180 mid-utterance
  examples across chat, email, code, commits, search, and notes, scored on first-word accuracy and
  type-through length (matched leading words). Replaces the encyclopedic held-out set that didn't
  predict in-product behavior. `eval_compare.py` scores any number of sources side by side and
  ranks candidate distillation teachers.
- **Harness-vs-raw isolation + greedy default (`scripts/llama_server.cpp`).** A new `mode:"raw"`
  decode path (same weights, greedy, none of the harness logic) lets the model be measured apart
  from its sampler/shaping/gate. The diagnostic showed the tuned nucleus sampler was *costing*
  accuracy on real typing, so the completion sampler now defaults to **greedy** (the anti-loop
  penalty is retained); `TYPER_SAMPLER=nucleus` restores the old one. +1 first-word / +0.04 matched
  on the new model, neutral on the old.
- **Claude-distilled typer-1 (`training/distill_teacher_batch.py`).** Teachers measured directly on
  the typed eval: Gemma 31% first-word, Claude Haiku 37%, Sonnet 43%. The distillation contexts were
  relabeled with Claude over the Message Batches API (50% off, resumable; assistant-register outputs
  filtered out) and the student retrained at matched capacity — raw first-word 28% → 31%, matched
  0.47 → 0.53. A community full fine-tune (`typer-1 v1`, HuggingFace-hosted) reaches 35% / 0.61, the
  strongest on-device result, two points behind the Haiku teacher.
- **Human-grounded data pipeline (`training/collect_human_data.py`, `expand_human_data.py`,
  `mine_capture.py`, `merge_synth.py`).** Grounds the training set in real human writing instead of
  model prose: interactive elicitation of your own continuations, privacy-filtered mining of accepted
  local capture, teacher-assisted expansion that preserves your register/length/slang, and provenance
  tags so each source can be ablated. Wired to the Batch API for scale, capped under a memory guard.
- **Research writeup.** A full methodology paper at [typr.frgmt.xyz/research](https://typr.frgmt.xyz/research)
  (`web/research/`): the eval design, the harness finding, the teacher comparison, and the honest
  limitations. The site now auto-deploys on push via a GitHub Action.

## Model size choice, first-run onboarding, and in-app updates

- **Small / Large model choice (`TyperApp+Model.swift`, `ModelDownloader.swift`, `ModelRouter.swift`).**
  `Small` is the on-device typer-1 0.6B race (default); `Large` is `typer-1l.gguf` (~1.2 GB, best on
  16 GB+ of RAM), served as a single model and downloaded on demand from HuggingFace with a progress
  bar, then switched live with no restart. Choose it from the menu dropdown or onboarding;
  `model_variant` records the choice. The small-race glob tightened to `typer-1-` so the large file
  isn't pulled into the race.
- **First-run onboarding (`OnboardingWindow.swift`).** A multi-step window on first launch: welcome,
  permissions (live Accessibility + Screen Recording status), model choice, and how-to. Gated by
  `onboarding_complete`.
- **In-app updates (`update.sh`, menu ↻).** `build.sh` stamps the source checkout path + built
  commit into the bundle; `update.sh` fast-forwards to the latest, rebuilds, and relaunches; the
  menu's ↻ button reports how many commits behind you are and runs it in the background
  (`~/Library/Logs/Typer-update.log`). Fast-forward only, so local changes are never overwritten.
- **Docs split.** The README is slimmed to getting-started + updating; build, architecture,
  configuration, and the training pipeline moved to a new `CONTRIBUTING.md`.

## Typo correction grows a foundation, and a round of fixes

Typo correction gained a proper abstraction and the start of grammar support (both still off by
default), and a few review-found bugs are fixed.

- **`Correction` abstraction + grammar foundation (`Correction.swift`, `TyperApp+Typo.swift`).**
  Spelling was refactored onto a `Correction` value type (kind / replacement / message / AX span)
  with no behavior change, and on-device grammar checking (`NSSpellChecker.requestChecking`,
  advisory-only, run off the main thread with staleness guards) drops in behind `grammar_enabled`
  (off by default). New opt-in quality knobs — guess ranking by edit distance / QWERTY adjacency /
  your vocabulary, a confidence gate, case-only fixes, and learn-from-rejections — all default to
  the previous behavior.
- **Typo path no longer drops a completion's outcome (#3).** Finishing a misspelled word over a live
  completion now resolves its accept/reject signal (race, feedback, training log) before showing the
  fix, instead of dropping it and overwriting the pending training example.
- **Debounced saves persist the latest state (#2).** `FeedbackMemory` and `RouterMemory` re-read
  state at fire time instead of encoding a snapshot captured when the save was scheduled, and a new
  `applicationWillTerminate` flushes the learning + training stores on quit so a ⌘Q can't roll back
  the last few seconds.
- **`stats.json` written `0600`, atomically (#4).** Matches every other store and the documented
  privacy guarantee.
- **Menu no longer beachballs.** Removed a `.fixedSize` on the popover root that, combined with the
  hosting controller's `preferredContentSize` sizing, formed an infinite layout loop the moment the
  popover opened.

## typer-1 is now Qwen3-0.6B, and two variants race for the slot

The SmolLM2-360M `typer-1` hit a capacity ceiling — on a clean held-out set drawn from the
registers people actually type in (chat, code, email, commits) it was the **worst** model we
had (matched-words 0.197 vs raw Qwen3-0.6B's 0.401). The earlier "matches Gemma" number was
real but measured on encyclopedic prose, which isn't how anyone types. So the base changed.
**typer-1 is now Qwen3-0.6B-Base**, shipped as a two-model race; Gemma is retired from the
runtime (both 0.6B models match it on real registers at ~3.7× the speed and ~1/5 the size).

- **Two-model graded-reward race (`ModelRouter.swift`, rewritten).** Two models whose names
  begin with `typer-1` — a raw base and a Gemma-distilled variant — are routed 50/50 and earn
  a *graded* reward per suggestion: Tab/backtick = 1.0, a type-through pays 0.25 per word
  followed, an ignored suggestion 0. Share shifts toward the higher average reward and **locks
  the winner at 80%**. Replaces the single-candidate-vs-Gemma ratchet. The share + per-model
  reward windows persist in `router.json`; "Reset model race" restarts it.
- **Gemma→0.6B distillation pipeline (`training/`).** `distill_teacher.py` does sequence-level
  KD — Gemma labels ~9k real/synthetic/corpus contexts over the app's own server, so the
  student imitates the teacher's *in-app* behavior (logits aren't needed; GGUF only exposes
  text). `build_distill_sft.py` filters by teacher confidence + dedup and mixes a **10%
  general-prose replay anchor** (the anti-forgetting key); `distill.yaml` sets the LoRA recipe
  (rank 32 / scale = α·2r, LR 1e-4 cosine, skip the first 4 layers). Result: the first
  fine-tune to *raise* a clean metric with zero forgetting (prose matched-words 0.43 → 0.49) —
  but it trades register terseness for prose fluency, which is why both raw and distilled ship
  and race for real instead of one being declared the winner offline.
- **Research-grounded recipe.** A literature pass set the approach: sequence-level KD (not
  on-policy at this scale), confidence-filtered teacher outputs, ~10% replay against
  catastrophic forgetting, and KTO-over-SFT for the next personalization stage. Qwen3-0.6B
  ships native FIM tokens, so fill-in-the-middle (suffix-aware completion) is a de-risked v2
  once the server stops banning special tokens.
- **Custom menu-bar UI (`MenuPopover.swift`).** The stock `NSMenu` is replaced by a SwiftUI
  popover: a green/red status dot, a model-preference bar (raw vs distill, green when locked),
  real switch toggles, and the rarely-touched controls folded into three collapsible sections.
  No emojis. "Disable in <app>" targets the app you were in when the popover opened, not Typer.
- **On-device personalization paused.** The SmolLM2 retrain agent is unloaded (it would fight
  the new base); personalization resumes once re-baselined to Qwen3-0.6B with KTO on the real
  accepts the race is now collecting. Old SmolLM2 models are backed up under
  `~/Library/Application Support/typer/backup-smol-*`.

## typer-1 — our own model, live behind a self-tuning A/B rollout

Typer now ships **its own model.** `typer-1` is a SmolLM2-360M-Base cold-start, fine-tuned
for this exact task and served behind a runtime A/B router that starts at 10% and ratchets
itself up as it earns real accepts — falling back to Gemma the moment it doesn't. On a
held-out set it **matches Gemma's next-chunk quality** (first-word acc 0.453 vs 0.460,
matched-words 0.96 vs 1.01) while being **~4× faster** (time-to-first-token p50 35 ms vs
163 ms — under the 100 ms "feels instant" bar Gemma misses) and **~9× smaller** (386 MB
Q8_0 vs 3.5 GB). This lands M1–M5 of [`docs/autocomplete-model.md`](docs/autocomplete-model.md).

- **Progressive A/B rollout with an auto-ratchet (`ModelRouter.swift`).** The router serves
  a growing *share* of suggestions from `typer-1` instead of the default — bumping the share
  up while typer-1's real accept rate keeps pace, multiplicatively backing off (bringing the
  default back) when it regresses, and a tripwire that drops straight to the floor on a burst
  of rejects. "Good" is a Tab/backtick accept or a long type-through — the same de-confounded
  reward the trainer uses, so the live rollout and offline training agree on what a win is.
  The share is persisted (`router.json`), per-model attribution flows into the training
  capture, the menu shows the live share + per-model accept rates, and "Reset typer-1
  rollout" restarts it. No-op (100% default) until a `typer-1*.gguf` exists, so it ships dark
  and lights up on its own.
- **Model-agnostic inference server (`llama_server.cpp`).** `prompt_complete()` no longer
  hardcodes the literal `<bos>` (Gemma-only); the real BOS is prepended at tokenize time via
  `add_special = llama_vocab_get_add_bos(vocab)` — Gemma still gets one, SmolLM2/Qwen base
  get none. `init_biases()` now bans control/special/added tokens **by id** from the actual
  vocab instead of tokenizing Gemma literal strings (the old `"<|"`/`"|>"` list tokenized to
  ordinary `<`,`|` byte-pairs in a byte-level-BPE vocab and would have blocked code output).
  Verified coherent on both models — the M1 change the design doc flagged as *not* a drop-in.
- **Ultra-efficient, resumable training (`training/`).** A one-command `train.sh cold-start`:
  `fetch_corpus.py` streams a bounded, categorized general seed (OpenAssistant→chat,
  Dolly→docs, FineWeb-Edu→web, CodeParrot→code) so the model learns general inline completion
  before it ever tailors to one user. SFT runs under **~1 GB RAM** — a 4-bit QLoRA base,
  batch 1 × grad-accumulation, short sequences, gradient checkpointing, LoRA on only the top
  layers — and is **chunked + checkpointed**, so a sleep, a closed lid, or a Ctrl-C costs at
  most one chunk and re-running resumes. The GGUF is produced directly at Q8_0 by
  `convert_hf_to_gguf.py`, so no llama.cpp C++ build is needed.
- **Honest data readiness.** `build_dataset.py` prints a per-model readiness report — genuine
  accepts vs the ≥300 the design doc requires for real personalization (KTO) — so "cold-start
  vs tailor" is never a guess. Today: a strong cold-start shipped, with personalization
  waiting on the rollout to collect real accepts attributed to typer-1.

## own autocomplete model — data foundation + training pipeline (replace Gemma)

Groundwork for replacing the ~3.5 GB Gemma the app ships with **our own sub-1B,
Apache-2.0 model** — fast on Apple Silicon, cheap to train, calibrated for this narrow
task. This lands the *data foundation* and *training pipeline*; training and the model
swap follow the plan in [`docs/autocomplete-model.md`](docs/autocomplete-model.md).

- **On-device training capture (opt-in, OFF by default).** A new menu toggle,
  *"Record my typing to train a local model,"* writes one JSON line per shown
  suggestion to `~/Library/Application Support/typer/training.jsonl` — the context, the
  suggestion, whether you accepted it and **how** (Tab / backtick / typed-through), the
  confidence, and below-gate suppressed suggestions. The accept/reject signal is the
  reward; `accept_kind` lets training tell a real Tab accept (information you didn't
  type) from a type-through (you'd have typed it anyway). `0600`, wiped by "Reset All
  Data," documented in `config.toml` (`training_log_enabled`). See `TrainingLog.swift`.
- **Privacy first.** `context` is only the immediate text you typed — never the
  folded-in window/clipboard/OCR background. Anything secret-shaped (emails, URLs, long
  digit runs, keys, paths) is dropped at capture, capture is skipped in password
  managers and secure-input fields, and enabling it shows a one-time sheet explaining
  exactly what's stored (with an "Inspect training data…" item). Nothing leaves the Mac.
- **Training pipeline (`training/`).** `build_dataset.py` turns the capture + your
  `style.txt` + public corpora into SFT/KTO/DPO/calibration sets in the app's exact
  prompt format; `synth_negatives.py` manufactures cold-start preference data (no users
  or teacher needed); `tokenizer_preflight.py` enforces the hard space-prefixed
  word-boundary contract on any candidate base; `calibrate_gate.py` re-fits
  `min_confidence` and reports good/junk **separation** as a model-selection gate;
  `eval.py` benchmarks a candidate GGUF over the real server protocol; `train.sh`
  runs the stages on Apple Silicon (mlx-lm) out to a quantized GGUF.
- **Design doc.** `docs/autocomplete-model.md` — the locked build plan from a
  research + adversarial-review pass: base-model + tokenizer decision (Qwen3-0.6B-Base
  / SmolLM2-360M-Base), the de-confounded KTO recipe, the on-device-only privacy
  architecture, and a milestone roadmap. Notes the required `llama_server.cpp` BOS
  change (the literal `<bos>` is Gemma-only — *not* a drop-in for other tokenizers).

## personalization + tracking — suggestions that sound like you, a ghost that keeps up

Two complaints drove this pass: suggestions felt random (not "how I type"), and the
ghost text lagged fast typing badly enough to be typed over — worse after a paste.

- **Confidence gate ("show less, but right").** The helper now reports the model's
  mean token probability with every partial and final completion, and suggestions
  below a configurable bar (`min_confidence`, default 0.22 — calibrated so observed
  garbage like "use a ." at 0.20 dies while good completions at 0.27+ survive) are
  simply never painted. Most of what made suggestions feel random was the model
  guessing; now it stays quiet instead.
- **Personal vocabulary lexicon.** Typer learns a frequency table of the words you
  actually type (letters-only, stop-words excluded, local JSON, clearable). The top
  ~48 words ride along with each request and the helper gives their leading tokens a
  gentle +0.5 logit bias — completions lean toward *your* vocabulary, not generic
  prose. Toggle: "Learn my vocabulary" / `lexicon_enabled`.
- **Accept/reject feedback loop.** Every suggestion now resolves as used (Tab,
  backtick, or typing straight through it) or rejected (typed over / Esc), persisted
  locally. Two adaptations come out of it: suggestion length tracks the median you
  actually take (someone who grabs 1–2 words gets short, dense suggestions), and the
  confidence bar tightens when most suggestions get rejected, relaxes when nearly
  everything is used. Toggle: "Adapt to my accepts" / `adaptive_suggestions`.
- **Per-app voice in style memory.** Style samples are now tagged with the app
  register they came from (chat/email/docs/code/browser) and sampling prefers lines
  matching where you're typing *now* — Messages-you and Docs-you no longer share one
  blended voice. Existing style.txt entries keep working untagged.
- **Paste/cut/undo duck-out.** ⌘V/⌘X/⌘Z previously fell through a "command key —
  ignore" early-return: the ghost stayed frozen over the pasted text and the keystroke
  buffer went stale. They now instantly hide the suggestion, cancel in-flight
  generations, and re-sync the buffer from Accessibility once the host app has applied
  the edit — so the next suggestion builds on what's really in the field.
- **Per-app ghost width calibration.** The ghost advances by text width measured in
  OUR font; hosts with wider fonts made every keystroke land on top of the ghost until
  a re-anchor caught up. Typer now compares its predicted advance against the real
  caret movement at each settled re-anchor and learns a per-app correction ratio
  (EMA), so the optimistic per-keystroke shift is right for that app's actual font.
- **Event-driven re-anchoring (AXObserver).** Instead of guessing with fixed 90ms /
  280ms timers, Typer now subscribes to `AXValueChanged`/`AXSelectedTextChanged` on
  the focused element and re-anchors the instant the host app reports it applied the
  edit. The timers remain as a fallback for apps that don't emit AX notifications.
- Menu shows vocabulary size and recent suggestion-usage rate; "Reset All Data…" now
  also clears the lexicon and feedback history.

## perf + ergonomics — KV-cache-friendly prompts, rapid-Tab fixes, better caret placement

Inference latency and the feel of accepting suggestions, in one pass.

- **Stable context windows (the big inference win).** The prompt's before-cursor
  window was a plain `suffix(500)` (and `last 1600 bytes` in the helper), which slides
  forward one character per keystroke — so the prompt's first tokens differed on every
  request and the helper's KV prefix cache *never* matched once a field passed 500
  chars: every pause re-decoded the whole prompt. The window start now snaps to a text
  boundary (newline / sentence end / word) on both the Swift and C++ sides, keeping the
  prompt prefix byte-identical across keystrokes until the boundary scrolls out. In a
  simulated 800-keystroke run the prefix changed 12 times instead of 800 — generation
  now usually decodes only the few new tokens instead of hundreds.
- **Stable style sample.** The style-memory sample was re-ranked against the live text
  on every generation, reshuffling the middle of the prompt (another KV-cache killer)
  and burning main-thread time per keystroke. It's now cached for a few seconds and
  re-ranked on app switch.
- **Rapid Tab no longer tabs you out of the field.** The consuming accept tap tore
  down the instant a suggestion was exhausted, so the second of two quick Tabs leaked
  to the host app — moving focus or inserting a literal tab mid-sentence. After an
  accept exhausts the suggestion, the tap now stays armed for a short grace window and
  swallows Tabs while the next chunk is on its way (typing any real character ends the
  window immediately, and Esc/clicking always restores normal Tab).
- **Faster next chunk after an accept.** Exhausting a suggestion via Tab/backtick now
  schedules the next generation after ~60ms (just long enough for the host app to apply
  our insertion) instead of the full typing debounce — there are no keystrokes to
  coalesce when the user explicitly asked for more.
- **Multi-Tab ghost drift fixed.** The ghost advances optimistically by measured text
  width on each accept (deliberately overshooting), and the quick re-anchor refused to
  snap backwards — so repeated Tab accepts accumulated rightward drift. A second,
  authoritative re-anchor now runs after the host app has definitely caught up and
  snaps the ghost exactly onto the caret, backwards included.
- **Caret reads remember which AX API the app answers.** Whether an app exposes its
  caret via `AXTextMarker` (WebKit/Chromium) or `AXBoundsForRange` (native AppKit) is
  toolkit-level and never changes, so it's now cached per bundle — caret reads happen
  on every re-anchor, and probing the wrong API first cost two failing synchronous IPC
  round-trips each time.
- **Better last-resort placement in single-line fields.** When an app exposes no caret
  geometry at all, the fallback now vertically centers on short fields (search bars,
  chat boxes) instead of guessing 24px down from the field top.
- **Helper micro-costs.** Single generated tokens are decoded via a stack-allocated
  batch (the general path heap-allocated six vectors per token), the JSON
  encoder/decoder in the Swift client is reused across requests, and `<cmath>` is
  included explicitly for `INFINITY`.

## refactor — split the menu-bar app into per-topic files

- **No more single hell file.** The 2,487-line `scripts/typer_native.swift` is split
  into [`scripts/typer/`](scripts/typer): one file per supporting type (`LlamaClient`,
  `SuggestionOverlay`, `GhostView`, `StyleMemory`, `TopicMemory`, `TyperConfig`,
  `TyperStats`, logging, power state, helper protocol) and the `TyperApp` class broken
  across `extension TyperApp` files by concern — `EventTap`, `Completion`, `Typo`,
  `Caret`, `Context`, `Menu`, `Input`, `Stats`. `main.swift` is the entry point.
- **Pure rearrangement.** No behavior changed: the substantive code lines are an
  identical multiset to the original, and the app builds via `swiftc` the same way
  (`build.sh` now compiles `scripts/typer/*.swift` as one module).

## ergonomics — click-safe generation, better caret anchoring, safer typo accept

- **Clicking is not typing.** Mouse/cursor placement now clears pending suggestions,
  invalidates in-flight generations, and refreshes context in the background without
  scheduling a completion. Suggestions only appear after actual text input.
- **Ghost overlay stays ahead of type-through.** The overlay now prefers WebKit/
  Chromium `AXTextMarker` caret geometry, keeps an optimistic forward-shift when AX
  reports a stale same-line caret, and slightly biases measured type-through movement
  forward so the ghost doesn't muddy the current word.
- **Prompt context is more relevant.** The helper context window grew (1024 → 1536),
  prompt text cap increased (1600 → 2200), conversation/background context is labeled
  ahead of the live text, and style-memory examples are selected by relevance to what
  you're currently typing instead of pure recency.
- **Sampler tuned for chat relevance.** Sampling is still conservative, but less
  brittle: top-k/top-p/min-p/temp were loosened slightly so completions can adapt to
  Discord/iMessage-style conversational phrasing instead of collapsing into generic
  continuations.
- **Typo replacement is harder to corrupt.** AX replacements are verified after the
  write, WebKit/Electron-like fields use the keystroke deletion/paste path instead of
  trusting stale AX selection writes, and the fallback sequence is paced so `helol` →
  `hello` and `there was a dgo ` → `there was a dog ` replace the word rather than
  interleaving text (e.g. `ththeis`).

## typo correction — fixed accept in Electron/Chromium apps

Accepting a spell-fix (<kbd>Tab</kbd>) now actually replaces the misspelled word in
Electron/Chromium editors (Discord, Slack, VS Code) instead of inserting the correction
in the wrong place, and the suggestion shows reliably on <kbd>Space</kbd>.

- **AX write is verified, not trusted.** Chromium apps return `.success` for setting
  `kAXSelectedTextRange` but silently ignore it, so the correction was being inserted at
  the live caret (e.g. `peopel` → `peoplepeopel`). The range is now read back and the AX
  path is only used when the selection actually moved; otherwise we fall back to keys.
- **Keystroke fallback deletes, doesn't select.** Synthetic `shift`+arrow selection is
  also dropped by editors like Discord's ProseMirror, which pasted the fix at the word's
  start. The fallback now Backspaces the word by its exact length, pastes the fix, and
  restores the caret after the separator you typed.
- **Injected keys are tagged.** Synthetic arrows/Backspace/paste now carry the
  `syntheticMarker`, so the event taps don't re-process them — an untagged Backspace was
  hitting the buffer's delete handler.
- **Misspelling beats follow-along.** Typing the separator that ends a misspelled word
  now surfaces the fix even while an inline completion is showing (previously a matching
  <kbd>Space</kbd> was swallowed as "typing along the ghost", so only punctuation like
  `/` triggered it). Correctly-spelled type-along is unchanged.

## topic memory — resurface what you were just reading

A new opt-in context source. Every few minutes Typer OCRs the focused window (Apple
Vision, on the Neural Engine — no extra model), distills the **salient topics** (named
entities + repeated content nouns) and a short snippet via Apple's NaturalLanguage, and
stores them locally. Later, when you start typing and mention one of those things, the
snippet is folded into the prompt so it can help you recall it — e.g. read a product
page, then tell a friend "those Sony headphones I saw…" and the details resurface.

- **Distilled, not dumped.** It stores entities + a 1–2 sentence note, never the raw
  screen text, and only injects it **when a distinctive keyword you read is actually in
  what you're typing** (no influence otherwise).
- **Cheap + private.** Capture is periodic (`topic_capture_seconds`, default 180, min
  60), single-flighted, skipped on battery-saver, during secure input, in disabled
  apps, and in **terminals** (noisy/sensitive). On-device; `topics.json` is `0600`;
  cleared by Reset All Data. **Off by default** (needs Screen Recording). Toggle:
  menu → Context sources → "Remember what I read".

## site — lazy-load Three.js on the landing page

- `scene3d` (Three.js) is now a dynamic `import()` gated on WebGL + non-reduced-motion,
  so the **initial JS bundle dropped from ~508 kB to ~3.7 kB**. The 505 kB scene chunk
  is fetched only when the animation can actually run; reduced-motion / no-WebGL
  visitors get just the command, no Three.js download.

## 6e85d46 — helper: cheaper per-token shaping + sampler setup

- `make_sampler` accepts only the last 64 prompt tokens (the penalties window) instead
  of replaying the whole ~1024-token prompt through `accept()` every request.
- The streaming callback runs `first_line_clean` once per token and skips the
  O(context) `remove_echo` back-off scan on partials — only the final result de-echoes.
- Dropped the unused `max_words` parameter from `prompt_complete`, and deleted the
  dead LLM typo path (`prompt_typo`/`last_word`/task routing); typo correction is local
  (`NSSpellChecker`), so the helper now only ever does completion.

## 71a919d — prefetch yields the helper; no warmup when completions off

- `LlamaClient.request` gained a `lowPriority` (try-lock) mode: a speculative prefetch
  is skipped rather than queued if a foreground request holds the single helper, so it
  can never delay real input.
- The model isn't warmed at launch unless inline completion is enabled.

## f59e3da — remove hot-path disk + logging I/O

- `StyleMemory` keeps an in-RAM mirror, so `style.txt` is no longer read from disk on
  every generation/prefetch (it was a synchronous main-thread read up to 40KB).
- `log()` writes through one long-lived `FileHandle` on a serial queue instead of
  open→seek→write→close per call; per-keystroke caret/AX diagnostics are now `dlog`
  (gated off by default). These ran several times per keystroke on the main thread.
- Streaming partials re-anchor (an AX caret read) only on the first frame, not per
  token. The AX paragraph back-scan is capped at 40 (was 400) synchronous IPC calls.
- Dropped a redundant `rebuildMenu()` from the typo show/accept path.

## 5802e3e — cleanup: dead code, redundant modifier tracking, half-baked grammar

- Deleted 7 unused functions (`focusedWindowBounds`, `replacePreviousWord`,
  `selectedOrWordRect`, `textBeforeCursor`, the 3 `test*` stubs) and write-only fields
  (`generationSerial`, `shift`, `acceptedWords`, `pendingTypoElement/Range`).
- Dropped `keyUp` interest + `setModifier` and the Shift/Cmd/Ctrl/Opt booleans; the
  keyDown's `event.flags` already carries modifier state, so the observer tap no longer
  wakes on key *release* (≈half the observer callbacks).
- Removed the half-implemented grammar feature (the helper never had a grammar branch)
  and the LLM typo routing — completions-off now never invokes the helper at all.
- Renamed `MLXClient`/`MLXRequest`/`MLXSuggestion` (the backend is GGUF/llama.cpp).
- Net: ~120 fewer lines, no behavior change to the completion path.

## 3d12cb3 — menu-bar badge: keyboard SF Symbol + count

A text-only `NSStatusItem` can lay out to zero width and render invisibly — the item
was present but unseeable in the bar. The button now carries an SF Symbol image
(`keyboard`, template) with `imagePosition = .imageLeading` and the accepted count as
the title (`⏸` when paused). The image is set once (guarded on `button.image == nil`);
`updateStatusTitle()` only mutates the title thereafter.

## 5eb1393 — battery: kill accept-tap mach spin; screenshot-OCR caret off by default

Sampling the idle process showed ~60% CPU in `accept() → SLEventTapEnable →
_CGSEnableEventTap → mach_msg` — a blocking WindowServer round-trip fired in a loop.
This, not the model, was the drain.

- The consuming accept tap (`.defaultTap`, Tab/backtick) was re-enabled on every
  `tapDisabledByTimeout`/`ByUserInput` notification, including while nothing was
  showing — where our own `tapEnable(false)` echoes back as a disable and we re-enable,
  spinning. Tap state is now mirrored in `acceptTapEnabled`; `refreshAcceptTap()`
  early-returns when the desired state already holds, and the disabled-notification
  branch only re-arms when `completion`/`active != nil`. **Idle CPU 60% → 0%.**
- The screenshot+OCR caret locator (ScreenCaptureKit capture + `VNRecognizeTextRequest`,
  ANE-backed) ran on a ~1.2s / 6-char cadence for apps with no AX caret (terminals,
  custom editors) — far too hot to run continuously. Gated behind new
  `screenshot_caret_enabled` (default false) + menu toggle; recompute throttle loosened
  to 4s / 24 chars when enabled. AX/text-marker apps are unaffected.

## 9c3e0db — battery: pause-based debounce, battery-saver, chunked helper reads

- `debounce_ms` default 25 → 110. 25ms is shorter than inter-keystroke gaps
  (~80–200ms), so the trailing-debounce timer expired *between* keys and fired a full
  inference per character. 110ms coalesces a typing burst into one generation per pause.
- `PowerState`: IOKit `IOPSGetTimeRemainingEstimate()` vs `kIOPSTimeRemainingUnlimited`
  (cached 5s) OR `isLowPowerModeEnabled`. When `battery_saver` (default on) and on
  battery/LPM, debounce → `battery_debounce_ms` (300) and speculative prefetch is
  disabled (it runs a second inference per chunk, ~2× GPU work). Menu toggle shows
  "(throttling now)". Background-context refresh interval stretched to ≥10s while saving.
- Helper response reader replaced byte-at-a-time `poll`+`read` (≈2 syscalls/char) with
  4KB chunked reads + a leftover buffer split on `\n`. macOS energy impact is
  wakeup-dominated, so this cuts overhead during streaming.

## e3ea965 / d101a30 — overlay: Core Animation renderer + ghost-overlap re-anchor

- `GhostView` rewritten on Core Animation: `CATextLayer` in SF system font sized to the
  caret line, a trailing taper (`CAGradientLayer` root mask over the last ~20px), a
  one-shot shimmer (`CAGradientLayer` masked by a text layer, animated `locations`) and
  a fade-in (opacity + `transform.translation.y`) on fresh appearance only — not while
  typing through.
- Ghost no longer lags/overlaps typed text. The CGEvent tap runs *before* the host app
  applies the key, so a synchronous AX caret read is one step stale. The overlay now
  shifts by the measured width of what was typed immediately, then a coalesced
  `scheduleReanchor()` (0.05s) re-reads the true caret to correct drift/line-wrap.

## e824e3b / 0d69e29 / 15e8728 — event-tap rearchitecture, per-app disable, fast-Tab fix

- Two taps (cotabby-inspired): a **listen-only** observer at the head (cannot gate
  global input delivery) that builds buffer/state, plus a **consuming** accept tap at
  the tail, enabled only while a suggestion shows. Typer consumes no keys otherwise.
- Fast-Tab skipped-word fix: injected insertion events are tagged via
  `eventSourceUserData = syntheticMarker` and ignored by exact marker, replacing a
  count/timing guard that raced real keystrokes.
- Per-app disable (`disabled_apps`) + terminal skip (`disable_in_terminals`,
  `terminalBundleIDs`). Clipboard relevance filter (a long clip needs a shared word with
  the current context). Menu → Reset All Data… (NSAlert confirm) wipes style + stats,
  keeps config.

## 694dfc0 / 7423560 — clipboard-free insertion + drift/staleness fixes

- Accept inserts via a synthesized Unicode keystroke (`keyboardSetUnicodeString`), no
  pasteboard, with a self-suppression marker so it isn't re-processed as typing. The
  pasteboard path remains only for the off-by-default typo fallback.
- Ghost re-anchors at word boundaries (handles wrap), shifts by measured width within a
  word. Staleness matches on a trailing anchor (`suffix(80)`) so it survives the
  4000-char buffer cap and idle reset. `isMidLine(after:)` suppresses when any
  non-whitespace follows the caret on the line. Helper clears its KV cache on context
  front-truncation. `captureFocusedWindow` result race fixed (CaptureBox; frontPID
  snapshotted on main). Dead config knobs removed.

## 5885999 — security + robustness hardening (adversarial review)

Security & privacy:
- Never capture during macOS secure input (password fields, login window, `sudo`,
  password managers): no buffer, learning, logging, AX reads, or generation.
- Logs gated behind `debug_logging` (default off); log + `style.txt` are `0600`.
- Clipboard context skips concealed/transient items.
- `install.sh`: optional `TYPER_MODEL_SHA256`; reject path separators in the model
  filename. `build.sh`: safe array globbing for dylibs.

Robustness / concurrency:
- Event tap self-heals on `tapDisabledByTimeout`/`ByUserInput`.
- Off-main data race fixed — screenshot-caret + background closures snapshot
  buffer/config on the main thread.
- Helper reads time out (8s) and tear down a hung process so the next request respawns;
  warm-up is lock-safe; in-flight flags reset on all paths.
- Pasteboard serialized, restores all item types, guards `changeCount`.

Helper (C++): UTF-8-safe streaming partials, RAII sampler, `max_words` clamped.
Stats: honest accept-rate (promoted prefetches count as shown; per-keystroke "ignored"
counter removed).

## a7a7cf8 / 334cbdf / 37bfddb — sampling/anti-flicker, HTML strip, badge, fun stats

- `min-p` sampler (~6% of top-token prob) + lower temp/top-p; sampling settles at temp
  0.12, top-k 20, top-p 0.80, min-p 0.06, penalty 1.05. Far less random-word drift.
- Typing-through advances by measured char width instead of re-reading the jittery AX
  caret per key; panel stops re-ordering each update. Per-field caret-height floor
  prevents oversized ghost. Completions repeating post-caret text are dropped.
- `strip_html_tags` removes stray `<em>`/`</strong>` (keeps the `<` in `a < b`).
- Menu-bar badge `t|N` accepted count (live; `⏸` when paused) — later replaced by the
  icon badge (3d12cb3).
- Local stats: words/chars completed, daily streak / active days; playful scaling
  comparisons (Hobbit/LOTR/Harry Potter) and estimated time saved.

## ac27448 / e1d868d / 89430ab / 2aa3b65 / a51c917 — foundational alpha

Suggestion quality:
- Root cause: the helper never prepended Gemma's `<bos>` (tokenized with
  `add_special=false`), so the base model produced degenerate, repetitive output.
  `prompt_complete` now prepends `<bos>`. Confirmed the GGUF reports
  `chat_template=(null)` (a base model) → raw continuation is the correct strategy.
- Initial sampling tune (temp 0.65→0.20, top-k 40→20, top-p 0.92→0.90, penalty
  1.12→1.08). Preserve the model's spacing intent (a leading-space token means "new
  word") to fix `"autocompl ition"` / `"cool !"`. Suppress mid-word continuations the
  small base model gets wrong.

Caret & overlay:
- AX→AppKit coordinate flip uses the primary (zero-origin) screen height (multi-monitor
  fix).
- `isPlausibleCaretRect` validation + fallthrough: selection → zero-length caret → prev
  glyph → next glyph → paragraph scan.
- `AXTextMarker` caret (`AXSelectedTextMarkerRange` → `AXBoundsForTextMarkerRange`) for
  Chromium/WebKit (Discord/VS Code/Chrome/Safari) — exact caret, no screenshot.
- Screenshot+OCR locator (ScreenCaptureKit + Vision) as last resort; cached +
  extrapolated. (`CGWindowListCreateImage` is unavailable in the macOS 26 SDK.)
- Inline render: font sized to the caret line height, vertically centered; applies to
  completions, typo, grammar.

Speed & ergonomics:
- Follow-along: matching keystrokes consume the ghost prefix without regenerating; only
  deviation/exhaustion triggers a new request.
- Single-flight generation (killed an 831-req → 18-shown stale-discard storm); the
  result is reconciled against typed-since text.
- Token streaming (JSONL `{"p":...}`, deduped, stop at sentence end); UI paints live.
- Speculative prefetch near exhaustion; debounce 80 → 25ms (later 110, see 9c3e0db).
- Huge-`AXValue` guard (terminals expose ~400k chars) → keystroke-buffer fallback.

Context & personalization:
- AX context captures before + after the cursor; per-app sessions keyed by
  `bundleID|appName` (buffer/background/caret/prediction reset on switch).
- Background = window AX scrollback + clipboard; screen-OCR context off by default.
- Local style memory (`style.txt`, deduped sample primed into the prompt); accept/ignore
  stats persisted to `stats.json`.

Typo (off by default): reworked onto `NSSpellChecker` as a strikethrough diff; exact
AX-range replacement with keystroke fallback; the big AX read happens only on accept.

Menu bar: live toggles persisted to `config.toml`; shows model / accept-rate /
learned-style count; Clear Learned Style, Open Config…, Open Log…, Quit.

Packaging: builds against Homebrew llama.cpp (GGUF-only; MLX/Python fallback removed;
model auto-discovered); stable self-signed signing (`make_signing_cert.sh`, designated
requirement anchored to the cert, not the cdhash); repo cleaned for public release, MIT.

## 6ce4e70 / e64a35a / cb7d85b / 34dc5c5 / a536ee9 / b4fc854 — typr.frgmt.xyz site + docs

Marketing site at typr.frgmt.xyz (bun + vite + WebGL shader, Cloudflare-deployed):
instanced cubes that rise and diffuse to "generate" the command block (denoise reveal),
pokeball-style rattle, a typewriter command with a shimmering border, and faded
instanced-cube background streamers. Docs: README refreshed for streaming / text-marker
caret / OCR-off / typo-off; added this CHANGELOG.
