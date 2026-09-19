import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

extension TyperApp {
    // Rendered width of `s` at the current ghost font (used to advance the overlay
    // as the user types through a suggestion without re-reading the caret).
    func ghostWidth(_ s: String) -> CGFloat {
        // Measure in the font the overlay ACTUALLY renders with (the caret fix's font,
        // already clamped against the line height). Measuring in a system font while
        // drawing in the host's was a systematic type-through/Tab advance drift that the
        // widthScale EMA then had to absorb; the EMA now only carries the residual.
        let font = lastCaretFix?.font ?? NSFont.systemFont(
            ofSize: CaretGeometry.ghostFontSizing(axFontPointSize: nil, axFontHeight: nil,
                                                  lineHeight: lastCaretHeight, adjustment: 1).size)
        let measured = (s as NSString).size(withAttributes: [.font: font]).width
        // Bias slightly forward. The host app may use a wider font than our ghost
        // renderer; being a few pixels ahead is far less distracting than sitting on
        // top of the word the user is actively typing, and the delayed AX re-anchor
        // corrects any overshoot.
        return measured + max(1, CGFloat(s.count) * 0.8)
    }

    // Calibrated px-per-char correction for the current app (1.0 until learned).
    // ghostWidth measures in OUR font; the host app's font is systematically wider
    // or narrower, and this learned ratio is what closes that gap so the ghost
    // tracks fast typing instead of being overwritten by it.
    func widthScale() -> CGFloat { widthScaleByBundle[currentAppBundleAndName().bundle] ?? 1.0 }

    // Optimistically advance the cached caret by the calibrated width of `s`,
    // accumulating the raw (uncalibrated) advance for settle-time calibration.
    func advanceGhost(by s: String) {
        guard let p = lastCaretPoint else { return }
        let raw = ghostWidth(s)
        let moved = NSPoint(x: p.x + raw * widthScale(), y: p.y)
        lastCaretPoint = moved
        lastCaretFix?.pointAppKit = moved
        calibPredicted += raw
        // Spend the extrapolation budget: past 40 chars / a line change since the last
        // real fix, the cached point is fiction and the ghost hides instead of drifting.
        charsSinceCaretFix += s.count
        lineChangesSinceCaretFix += s.reduce(0) { $1 == "\n" || $1 == "\r" ? $0 + 1 : $0 }
    }

    // Compare how far the caret ACTUALLY moved since the last authoritative fix
    // with how far our font model predicted, and fold the ratio into the per-app
    // scale (EMA). Same-line moves only; a wrap or cursor jump just resets the anchor.
    func calibrateGhostWidth(authoritative ax: NSPoint) {
        defer { calibAnchor = ax; calibPredicted = 0 }
        guard let anchor = calibAnchor, calibPredicted >= 8 else { return }
        guard abs(ax.y - anchor.y) <= max(6, lastCaretHeight * 0.65) else { return }
        let actual = ax.x - anchor.x
        guard actual > 2 else { return }
        let ratio = min(1.6, max(0.7, actual / calibPredicted))
        let bundle = currentAppBundleAndName().bundle
        let updated = (widthScaleByBundle[bundle] ?? 1.0) * 0.65 + ratio * 0.35
        widthScaleByBundle[bundle] = updated
        dlog("[\(activeAppKey)] ghost width scale ratio=\(ratio) ema=\(updated)")
    }

    // A completion's lifecycle ended: count how many of its words the user actually
    // used (Tab/backtick accepts and typing straight through both count) and feed
    // the outcome to the adaptive layer (suggestion length + confidence gate).
    func resolveCompletionOutcome(_ comp: ActiveCompletion, via kind: String) {
        let used = String(comp.chars[0..<comp.consumed])
            .split(whereSeparator: { $0.isWhitespace }).count
        if cfg.adaptiveSuggestions { feedback.recordResolution(usedWords: used) }
        // Feed the same outcome into the typer-1 rollout, attributed to the model that
        // produced this suggestion. The ratchet uses it to grow or shrink typer-1's share.
        router.record(pick: routedModel, accepted: used > 0, kind: kind, words: used)
        // Universal resolution path (Tab/backtick accept, type-through, divergence, Esc),
        // so it captures both accepts and rejects with the final consumed count and HOW
        // it was taken — so a real Tab accept can be weighted above a type-through (words
        // the user would have typed anyway) at training time.
        flushTrainingOutcome(consumedChars: comp.consumed, acceptKind: kind, reason: "resolved")
    }

    // MARK: - Training-data capture (opt-in; see TrainingLog)

    // GGUF filename the suggestions came from (the policy/version tag). Cached: the
    // model rarely changes and findModel touches disk.
    func currentTrainingModel() -> String {
        // The model the router actually served (set at pick time in generate). This tags
        // each captured example with the model that produced it, so a later rebuild can
        // train typer-1 only on typer-1's own accepts.
        if !routedModelName.isEmpty { return routedModelName }
        if trainingModelNameCache.isEmpty {
            trainingModelNameCache = (LlamaClient.findModel(cfg).map { ($0 as NSString).lastPathComponent }) ?? "unknown"
        }
        return trainingModelNameCache
    }

    // Safe to capture this context: logging on, not secure input, not a disabled or
    // credential app, and no secret-shaped content (passwords/codes/keys/paths).
    func canCaptureTraining(context: String, suggestion: String) -> Bool {
        guard cfg.trainingLogEnabled else { return false }
        if IsSecureEventInputEnabled() || isAppDisabled() { return false }
        if TrainingLog.sensitiveAppBundles.contains(currentAppBundleAndName().bundle) { return false }
        if TrainingLog.looksSensitive(context) || TrainingLog.looksSensitive(suggestion) { return false }
        return true
    }

    var trainingMaxWords: Int {
        cfg.adaptiveSuggestions ? feedback.adjustedMaxWords(base: cfg.maxCompletionWords) : cfg.maxCompletionWords
    }

    // Completion length cap in words (#9). The configured bucket is the ceiling; the
    // adaptive feedback layer (when on) nudges it toward how much the user actually
    // accepts. The helper converts words→a token budget and stops early on a clause
    // boundary, so a high bucket lengthens completions without forcing padding.
    func completionWordCap() -> Int {
        cfg.adaptiveSuggestions ? feedback.adjustedMaxWords(base: cfg.maxCompletionWords) : cfg.maxCompletionWords
    }

    // Personalized lexicon for the sampler (#10, Wave 4). Gated by the existing
    // `cfg.lexiconEnabled` feature flag AND by `cfg.personalizationStrength`, then routed
    // through the router's single personalization seam (`PersonalizationBias`), which scales
    // the word list by the strength. The router reads the strength here (not its init-time cfg
    // copy), so a slider change takes effect on the very next generation, and re-derives only
    // when the strength bucket or word list changes.
    //
    // Strength 0 means OFF, and now actually is: an empty list and no bias on the wire. It used
    // to mean "48 words at the historical 0.5 boost" — the comment claimed otherwise, and the
    // slider's own zero position therefore still shipped the full lexicon.
    func personalizedLexicon() -> String {
        guard cfg.lexiconEnabled, cfg.personalizationStrength > 0 else { return "" }
        // Pull a generous candidate pool (the router trims to the strength-scaled count); the
        // 60s-cached topWords keeps this off the disk on the hot path.
        let pool = lexicon.topWords(64)
        return router.lexiconString(words: pool, strength: cfg.personalizationStrength)
    }

    // Per-word logit-bias weight for the lexicon. The slider scales HOW MANY of the user's
    // words are sent (and how much style sample rides along); it does NOT scale how hard each
    // one is pushed. That ceiling is fixed at the evaluated +0.5 "gentle tie-break" — the value
    // the helper defaults to, the value `PersonalizationBias.maxBoost` documents, and the value
    // docs/autocomplete-model.md calls "the runtime +0.5 first-token boost".
    //
    // It used to be `0.5 + strength * 2.0`, i.e. +1.2 logits at the shipped strength of 0.35 and
    // +2.5 at the top of the slider. Under the helper's greedy decoding that is not a tie-break:
    // a boost that size simply overrides the model's own ranking, so any of the ~50 words in the
    // list beats whatever the model actually predicted. nil ⇒ helper default, which keeps the
    // wire byte-identical when personalization is off.
    func personalizedLexiconBias() -> Float? {
        guard cfg.lexiconEnabled, cfg.personalizationStrength > 0 else { return nil }
        return PersonalizationBias.maxBoost
    }

    // A suggestion was just shown: remember the context it continued so the eventual
    // accept/reject can be written as one example. No-op unless safe to capture.
    func noteTraining(context: String, suggestion: String, conf: Double?, source: String) {
        guard !suggestion.isEmpty else { return }
        let ctx = stableTail(context, max: 600).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ctx.count >= cfg.minContextChars, canCaptureTraining(context: ctx, suggestion: suggestion) else { return }
        pendingTraining = PendingTrainingExample(context: ctx, suggestion: suggestion,
                                                 conf: conf ?? 0, minConf: effectiveMinConfidence,
                                                 maxWords: trainingMaxWords, category: appCategory(),
                                                 source: source, model: currentTrainingModel())
    }

    // The shown suggestion left the screen with `consumedChars` of it taken, via
    // `acceptKind`. Write the record and clear the pending slot. Idempotent: safe to
    // call from multiple lifecycle points (only the first sees a pending example).
    func flushTrainingOutcome(consumedChars: Int, acceptKind: String, reason: String) {
        guard let p = pendingTraining else { return }
        pendingTraining = nil
        guard cfg.trainingLogEnabled else { return }
        let chars = Array(p.suggestion)
        let n = min(max(consumedChars, 0), chars.count)
        let takenWords = String(chars[0..<n]).split(whereSeparator: { $0.isWhitespace }).count
        let shownWords = p.suggestion.split(whereSeparator: { $0.isWhitespace }).count
        trainingLog.record(TrainingLog.Record(
            schema_version: TrainingLog.schemaVersion, ts: Date().timeIntervalSince1970,
            context: p.context, suggestion: p.suggestion,
            accepted: takenWords > 0, accept_kind: takenWords > 0 ? acceptKind : "none",
            words_accepted: takenWords, words_shown: shownWords,
            confidence: p.conf, shown: true, exploration: false, min_conf: p.minConf,
            max_words: p.maxWords, app_category: p.category, source: p.source,
            model: p.model, reason: reason))
    }

    // A generated suggestion was suppressed by the confidence gate (never shown). Log it
    // as a below-gate negative so the training set + gate recalibration cover the
    // suppressed region, not just the gate-passing survivors (fixes the survivorship
    // censoring that would otherwise blind the reward model). Written immediately.
    func noteSuppressed(context: String, suggestion: String, conf: Double) {
        let s = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        let ctx = stableTail(context, max: 600).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ctx.count >= cfg.minContextChars, canCaptureTraining(context: ctx, suggestion: suggestion) else { return }
        let shownWords = s.split(whereSeparator: { $0.isWhitespace }).count
        trainingLog.record(TrainingLog.Record(
            schema_version: TrainingLog.schemaVersion, ts: Date().timeIntervalSince1970,
            context: ctx, suggestion: suggestion,
            accepted: false, accept_kind: "none", words_accepted: 0, words_shown: shownWords,
            confidence: conf, shown: false, exploration: true, min_conf: effectiveMinConfidence,
            max_words: trainingMaxWords, app_category: appCategory(), source: "generate",
            model: currentTrainingModel(), reason: "suppressed"))
    }

    // The confidence bar a suggestion must clear to be shown: the configured base,
    // tightened when the user rejects most suggestions and relaxed when they accept
    // nearly everything.
    var effectiveMinConfidence: Double {
        guard cfg.minConfidence > 0 else { return 0 }
        let adj = cfg.adaptiveSuggestions ? feedback.confidenceAdjustment() : 0
        return min(0.9, max(0.05, cfg.minConfidence + adj))
    }

    // reanchor=true re-reads the caret from AX (fresh suggestion / new line);
    // reanchor=false reuses the cached point (already shifted by typed width) to
    // avoid per-keystroke AX jitter. trustAX=true drops the no-backward-snap guard
    // so a late re-anchor can correct accumulated forward overshoot.
    func showCompletionRemainder(reanchor: Bool = true, animate: Bool = false, trustAX: Bool = false) {
        guard let comp = completion, !comp.done else { overlay.orderOut(nil); return }
        let guardPoint = (comp.consumed > 0 && !trustAX) ? lastCaretPoint : nil
        let fix = reanchor
            ? resolveCaret(allowBackwardFrom: guardPoint)
            : (cachedCaretFix() ?? resolveCaret(allowBackwardFrom: guardPoint))
        // nil == we do not know where the caret is. Hide the ghost, but KEEP `completion`:
        // the suggestion is still valid and reappears the moment a fix lands (a failed
        // placement must never throw away a good suggestion).
        guard let fix else { overlay.orderOut(nil); return }
        overlay.showCompletion(comp.remainder, at: fix, animate: animate)
    }

    // Our tap callback runs BEFORE the host app applies the keystroke, so reading the
    // AX caret right after typing/inserting gives a stale (one-step-behind) position —
    // that's the ghost overlapping what you just typed. Move immediately by measured
    // width, then re-anchor to the real caret a beat later once the app has caught up.
    // Coalesced, so fast typing never triggers a synchronous AX read.
    func scheduleReanchor() {
        reanchorWork?.cancel()
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.completion != nil else { return }
            self.showCompletionRemainder(reanchor: true)
        }
        reanchorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
        // The quick re-anchor above keeps the no-backward-snap guard (the host app's
        // AX caret may still be a frame behind), but ghostWidth deliberately overshoots,
        // so repeated Tab accepts accumulate rightward drift the guard then refuses to
        // correct. Once the app has definitely caught up, snap to the authoritative AX
        // caret — backwards included — and use the trustworthy read to calibrate the
        // per-app width scale. Cancelled and re-armed on every keystroke, so it only
        // fires after a real pause.
        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.completion != nil else { return }
            if let fix = self.resolveCaret(), fix.isAuthoritative {
                // Only a validated AX rect may teach the width model.
                self.calibrateGhostWidth(authoritative: fix.pointAppKit)
                self.showCompletionRemainder(reanchor: false)
            } else {
                self.showCompletionRemainder(reanchor: true, trustAX: true)
            }
        }
        settleWork = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: settle)
    }

    // Tab: realize the next word of the prediction (we insert it; the user did not
    // type it) and keep the remainder showing.
    func acceptCompletionWord() -> Bool {
        guard var comp = completion, !comp.done else { return false }
        let end = comp.nextWordEnd()
        let piece = String(comp.chars[comp.consumed..<end])
        lastUserTypedAt = Date()
        insert(piece)
        // The MODEL wrote this, not the user. Marked unlearnable so it never becomes
        // "their vocabulary" or "their voice": learning it back would close the loop —
        // the word enters the lexicon, the lexicon gives it a logit boost, the model
        // emits it more often, and typer ends up personalizing to itself.
        unlearnableSource = .model
        appendToBuffer(piece, learnable: false)
        comp.consumed = end
        stats.accepted += 1; recordCompleted(piece); statsTouched()
        if comp.done {
            // Arm the grace window BEFORE completion=nil so refreshAcceptTap (its
            // didSet) never bounces the tap off and back on. A rapid next Tab is then
            // swallowed instead of tabbing focus away while the next chunk arrives.
            armAcceptGrace()
            resolveCompletionOutcome(comp, via: "tab")
            completion = nil
            if !promotePrefetch() { overlay.orderOut(nil); scheduleGenerate(quick: true) }
        } else {
            completion = comp
            // Move immediately by the inserted word's width (the app hasn't applied
            // the insertion yet), then re-anchor precisely once it has.
            advanceGhost(by: piece)
            showCompletionRemainder(reanchor: false)
            scheduleReanchor()
            maybePrefetch()
        }
        return true
    }

    // Backtick: accept the whole remaining prediction at once.
    func acceptCompletionAll() -> Bool {
        guard let comp = completion, !comp.done else { return false }
        let piece = comp.remainder
        lastUserTypedAt = Date()
        insert(piece)
        unlearnableSource = .model      // typer's own text; never learned back (see acceptCompletionWord)
        appendToBuffer(piece, learnable: false)
        stats.accepted += 1; recordCompleted(piece); statsTouched()
        armAcceptGrace()
        var resolved = comp; resolved.consumed = resolved.chars.count
        resolveCompletionOutcome(resolved, via: "backtick")
        completion = nil
        overlay.orderOut(nil)
        scheduleGenerate(quick: true)
        return true
    }

    // As the user nears the end of the current prediction, generate the NEXT chunk
    // in the background (as if they had typed through the rest) so it can appear
    // with zero perceived latency on exhaustion.
    func maybePrefetch() {
        // Prefetch roughly doubles inference; skip it entirely while saving power.
        guard cfg.prefetchEnabled, !powerSaving else { return }
        guard let comp = completion, !comp.done else { return }
        guard comp.chars.count - comp.consumed <= 12, !prefetchInFlight, !requestInFlight else { return }
        let predicted = stableTail(buffer + comp.remainder, max: 500)
        if predicted == prefetchKey, prefetched != nil { return }
        prefetchInFlight = true
        let promptContext = assembledContext(immediate: predicted)
        let appKey = activeAppKey
        let maxWords = completionWordCap()
        let lex = personalizedLexicon()
        // Continue on the SAME model the current suggestion came from — a prefetch is the
        // tail of the same thought, and the eventual accept is attributed to routedModel.
        let prefetchClient = router.client(for: routedModel)
        backgroundQueue.async {
            let sug = (try? prefetchClient.request(task: "complete", context: promptContext, maxWords: maxWords, lexicon: lex, lexiconBias: self.personalizedLexiconBias(), lowPriority: true)) ?? nil
            DispatchQueue.main.async {
                self.prefetchInFlight = false
                guard appKey == self.activeAppKey, let t = sug?.text, !t.isEmpty else { return }
                // A prefetch below the confidence bar would be promoted (shown)
                // without ever passing through presentCompletion — gate it here.
                if let c = sug?.conf, c < self.effectiveMinConfidence { self.noteSuppressed(context: predicted, suggestion: t, conf: c); return }
                self.prefetched = ActiveCompletion(chars: Array(t))
                self.prefetchKey = predicted
                self.prefetchTrainImmediate = predicted   // context this prefetch continued (for training capture on promote)
                self.prefetchTrainConf = sug?.conf ?? 0
                log("prefetched chars=\(t.count)")
            }
        }
    }

    // If a prefetched chunk matches the current buffer state, show it instantly.
    func promotePrefetch() -> Bool {
        guard let pf = prefetched, prefetchKey == stableTail(buffer, max: 500) else { return false }
        // A promoted prefetch is shown without ever passing through presentCompletion, so
        // it has to clear the same two bars: no disallowed scalars, and not the text the
        // user already turned down for this context.
        let text = String(pf.chars)
        let tail = InputSanitizer.contextTail(prefetchTrainImmediate)
        guard TextSanitizer.isClean(text),
              !InputSanitizer.isRepeatOfRejected(lastRejected, contextTail: tail, suggestion: text) else {
            prefetched = nil; prefetchKey = ""
            return false
        }
        completion = pf
        prefetched = nil
        prefetchKey = ""
        stats.shown += 1; statsTouched()   // a promoted prefetch is a shown suggestion
        lastPresentedTail = tail
        lastPresentedAt = Date()
        noteTraining(context: prefetchTrainImmediate, suggestion: text, conf: prefetchTrainConf, source: "prefetch")
        showCompletionRemainder(animate: true)
        calibAnchor = lastCaretPoint; calibPredicted = 0   // fresh calibration epoch
        log("promoted prefetch")
        return true
    }

    func scheduleGenerate(quick: Bool = false) {
        debounce?.invalidate()
        var ms = powerSaving ? max(cfg.debounceMs, cfg.batteryDebounceMs) : cfg.debounceMs
        // An explicit accept that exhausted the suggestion is a direct request for
        // more. The debounce exists to coalesce keystrokes — there are none — so wait
        // only long enough for the host app to apply our insertion (the AX context
        // read must include it), not the full typing debounce.
        if quick { ms = min(ms, 60) }
        debounce = Timer.scheduledTimer(withTimeInterval: Double(ms) / 1000.0, repeats: false) { [weak self] _ in
            self?.generate()
        }
    }

    // An AXSelectedTextChanged that arrived while a generation was in flight or a debounce
    // was armed is deliberately not acted on there (at that moment the change is almost
    // always our own), but it used to be dropped on the floor, so a genuine external edit
    // landing inside that window was never re-synced at all. It is parked instead, and
    // drained here — at the two moments the window closes: the debounce firing, and the
    // request returning. Returns true when it fired, so the caller stops what it was doing.
    @discardableResult
    func drainExternalSelectionChange() -> Bool {
        guard pendingExternalSelectionChange else { return false }
        pendingExternalSelectionChange = false
        let now = Date()
        // Typing (or one of our own injections) since means the parked notification was
        // ours after all — the whole reason the guard exists.
        guard now.timeIntervalSince(lastUserTypedAt) > TyperApp.axSelfChangeWindow,
              now.timeIntervalSince(lastSyntheticAt) > TyperApp.axSelfChangeWindow else { return false }
        dismissForExternalEdit(reason: "AXSelectedTextChanged (deferred)")
        return true
    }

    func generate() {
        syncActiveApp()
        // A real external caret move was parked while this debounce was armed: honour it
        // instead of completing from a buffer we now know is wrong.
        if drainExternalSelectionChange() { return }
        // Never complete into our own UI (Settings/onboarding text fields): reading the
        // focused element / caret of a SwiftUI window AX-walks its a11y tree on the main
        // thread and beachballs. (Same reason as refreshBackgroundIfNeeded/updateAXObserver.)
        if frontmostIsSelf { clearSuggestion(); return }
        if isAppDisabled() { clearSuggestion(); return }    // per-app / terminal denylist (W1C: password mgrs always, IDEs by default, secure fields)
        // Timed snooze (#3, spec E §3): a global or per-app "Snooze for…" deadline
        // suppresses completions until it expires. Deadlines are ephemeral and pruned by
        // completionsAllowed as they pass; the menu's 1 Hz timer refreshes the countdown.
        if !completionsAllowed(bundle: currentAppBundleAndName().bundle) { clearSuggestion(); return }
        // Inline completion is the only LLM-backed feature (typo correction is local,
        // via NSSpellChecker). If it's off, never touch the model helper.
        guard cfg.enabled, cfg.completionEnabled else { clearSuggestion(); return }
        // Don't extend a word that looks misspelled (#8). No-op unless the user enabled
        // suppress_completion_on_typo_suspected. (review L2: was implemented but never called)
        if typoSuspectedInCurrentWord() { clearSuggestion(); return }
        // Only user text input should initiate completions. A click/focus change can
        // refresh context, but it must not create a suggestion; also ignore orphaned
        // timers that fire long after the typing burst that scheduled them.
        guard Date().timeIntervalSince(lastUserTypedAt) < 10.0 else { return }
        let serial = generationSerial
        // Single-flight: only one request may be in the helper at a time. Firing one
        // per keystroke (with ~400ms latency) backlogs the helper and every result
        // comes back stale — the cause of "nothing ever shows". If a request is in
        // flight we just remember to re-run with the latest context when it returns.
        if requestInFlight { rerequestNeeded = true; return }

        // Both context sources go through stableTail (not a sliding suffix) so the
        // prompt prefix stays byte-identical across keystrokes and the helper's KV
        // prefix cache actually hits. textAroundCursor applies it internally.
        // AX text is the single place invisible formatting gets in: an app's AXValue can
        // carry a byte-order mark or a bidi mark that nobody typed and nobody can see.
        // Strip it HERE, at the one point AX text enters the completion path, so it never
        // reaches the prompt, the training log or the buffer. (The grammar path in
        // handleTyping deliberately keeps the raw value — its UTF-16 offsets have to line
        // up with the app's own text.)
        let axCtx = textAroundCursor(limit: 500).map {
            AXContext(before: TextSanitizer.strippingInvisibles($0.before),
                      after: TextSanitizer.strippingInvisibles($0.after))
        }
        let axContextRaw = axCtx?.before
        // While a caret re-sync is pending the buffer still describes text at the OLD caret
        // position, and everything typed since the caret moved has been appended to the end
        // of it — so using it whole would hand the model stale text glued to text typed
        // somewhere else entirely. `typedSinceNav` is exactly the part that is still known
        // to sit in front of the caret; it is usually too short to clear `minContextChars`,
        // which is the correct outcome (say nothing rather than guess) until the re-sync
        // lands a few hundred milliseconds later and restores the full buffer.
        let keyContext = stableTail(navResyncPending ? typedSinceNav : buffer, max: 500)
        let axContext = (axContextRaw?.count ?? 0) >= max(cfg.minContextChars, min(20, keyContext.count / 2)) ? axContextRaw : nil
        let contextSource = axContext == nil ? "key-buffer" : "AXValue"
        let context = axContext ?? keyContext
        // Mid-line completion fidelity (#13). The caret sits inside existing text with
        // real characters after it on the line. Old behavior bailed outright; now we
        // complete only at a clean WORD BOUNDARY (the model would otherwise rewrite the
        // word being edited) and hand the trailing text to the helper as a FIM suffix so
        // the completion fits the gap instead of duplicating/ignoring what follows. The
        // repeat-drop guard below (and in presentCompletion) still catches a completion
        // that merely echoes the trailing text. Honors the global toggle + per-app
        // override (W0 `cfg.midLineCompletionsEnabled`, AppOverrides.midLineCompletionsDisabled).
        var fimSuffix = ""
        if axContext != nil, let after = axCtx?.after, isMidLine(after: after) {
            let midLineOK = cfg.midLineCompletionsEnabled &&
                OverrideStore.shared.resolved(bundle: currentAppBundleAndName().bundle,
                                              host: currentWebHost()).midLineCompletionsDisabled != true
            // Only complete from a word boundary: the char immediately before the caret
            // must be whitespace/empty, else we'd be mid-word and any continuation would
            // fight the word the user is editing.
            let atWordBoundary = context.isEmpty || (context.last?.isWhitespace ?? true)
            guard midLineOK, atWordBoundary else {
                log("[\(activeAppKey)] generate skipped mid-line (ok=\(midLineOK) boundary=\(atWordBoundary))")
                clearSuggestion(); return
            }
            // The line's trailing text becomes the FIM suffix (bounded; the helper caps it
            // again). Stop at the line end — completing across a hard newline isn't FIM.
            let lineTail = String(after.prefix { $0 != "\n" && $0 != "\r" })
            fimSuffix = String(lineTail.prefix(400))
            log("[\(activeAppKey)] mid-line FIM suffix chars=\(fimSuffix.count)")
        }
        // Remember the text right after the caret so we can drop completions that
        // just repeat it (e.g. at end of a line that already has following text).
        // Taken from AX whenever AX gave us anything at all — NOT only when AX also won
        // the contest for the prompt context. In an app whose AXValue is too short to beat
        // the keystroke buffer (exactly the AX-hostile fields where a completion is most
        // likely to duplicate what is already there) this used to be left empty, so the
        // echo-drop below simply never ran.
        lastTrailing = (axCtx?.after ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.count >= cfg.minContextChars else { log("[\(activeAppKey)] generate skipped context=\(context.count) source=\(contextSource)"); return }
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { log("[\(activeAppKey)] generate skipped question"); clearSuggestion(); return }
        refreshBackgroundIfNeeded()

        requestInFlight = true
        let appKey = activeAppKey
        let reqBuffer = buffer            // buffer snapshot for the staleness check
        let promptContext = assembledContext(immediate: context)
        // Completion length control (#9): the configured bucket (`cfg.maxCompletionWords`,
        // surfaced by W2A's segmented control) is the word cap; the adaptive layer nudges
        // it toward how much the user actually takes. The helper turns words→token cap and
        // stops early on a clause boundary so a long bucket doesn't pad.
        let maxWords = completionWordCap()
        // Personalization (#10): ship the user's vocabulary so sampling leans toward how
        // they write, with the count scaled by `cfg.personalizationStrength`. The logit-bias
        // MAP itself is W4 — this leaves the seam (strength already shapes lexicon weight +
        // the style-sample size in assembledContext).
        let lex = personalizedLexicon()
        let suffix = fimSuffix
        dlog("[\(activeAppKey)] generate source=\(contextSource) chars=\(context.count) promptChars=\(promptContext.count) bg=\(cachedBackground.count) suffix=\(String(context.suffix(50)).replacingOccurrences(of: "\n", with: "\\n"))")
        // Anchor (an AX caret read) only on the FIRST painted partial; the user hasn't
        // typed since the request (guard below), so the caret can't have moved while
        // the rest of the tokens stream in — reuse the cached point instead of reading
        // AX per token.
        // Pick the model for this generation (typer-1 vs the default). The choice serves
        // the whole generation; prefetch continuations reuse it (see maybePrefetch) so one
        // suggestion is never a mix, and the outcome is attributed to it on resolution.
        let (routedClient, pick, routedName) = router.pick()
        routedModel = pick
        routedModelName = routedName
        var firstPartial = true
        DispatchQueue.global(qos: .userInitiated).async {
            // Live preview: paint partial completions as they stream in, but only
            // while the user hasn't typed since the request (else it's the final
            // line's job to reconcile via presentCompletion).
            let onPartial: (String, Double?) -> Void = { partial, conf in
                DispatchQueue.main.async {
                    guard appKey == self.activeAppKey, self.generationSerial == serial,
                          self.buffer == reqBuffer, !partial.isEmpty else { return }
                    // Don't paint a stream the final gate would tear down — flashing
                    // and yanking a bad suggestion is worse than a moment of silence.
                    if let conf, conf < self.effectiveMinConfidence { return }
                    guard TextSanitizer.isClean(partial) else { return }
                    self.completion = ActiveCompletion(chars: Array(partial))
                    // A painted partial IS a presented suggestion: Esc on it records a
                    // rejection against `lastPresentedTail`, and the AX observer's guard
                    // asks when a completion was last put on screen. Leaving both unset
                    // here stored the rejection under an empty (never-matching) context.
                    self.lastPresentedTail = InputSanitizer.contextTail(context)
                    self.lastPresentedAt = Date()
                    self.showCompletionRemainder(reanchor: firstPartial, animate: firstPartial)
                    if firstPartial { self.calibAnchor = self.lastCaretPoint; self.calibPredicted = 0 }
                    firstPartial = false
                }
            }
            let sug = try? routedClient.request(task: "complete", context: promptContext, maxWords: maxWords, lexicon: lex, lexiconBias: self.personalizedLexiconBias(), suffix: suffix, onPartial: onPartial)
            DispatchQueue.main.async {
                self.requestInFlight = false
                let again = self.rerequestNeeded
                self.rerequestNeeded = false
                // An external caret move parked while this request was in the helper: act
                // on it now, and do NOT present a completion built for the old position
                // (nor re-request from the buffer it came from — the re-sync will).
                if self.drainExternalSelectionChange() { return }
                if appKey == self.activeAppKey, self.generationSerial == serial {
                    // `context` is what actually went to the model (AX text when it won,
                    // the keystroke buffer otherwise); `reqBuffer` is only the yardstick for
                    // "what did the user type since the request". The training log wants the
                    // former — it used to be handed the latter, so every row generated from
                    // AX text was stored paired with a context the model never saw.
                    self.presentCompletion((sug ?? nil)?.text, conf: (sug ?? nil)?.conf,
                                           requestedBuffer: reqBuffer, context: context)
                }
                // Always converge on the latest context.
                if again { self.scheduleGenerate() }
            }
        }
    }

    // Show a freshly generated completion, tolerating that the user may have typed
    // MORE since the request was issued: if they typed along the prediction we show
    // the remaining tail; if they diverged we regenerate.
    func presentCompletion(_ text: String?, conf: Double? = nil, requestedBuffer: String, context: String) {
        guard let text, !text.isEmpty else {
            // No usable result for this generation (empty, or gated/percentage-suppressed
            // at the final stage). A streamed partial of THIS generation may already be
            // painted — tear it down rather than strand a ghost on screen (e.g. a bare
            // "100" partial whose final the orphan-number gate nulls). Safe to clear: the
            // caller only reaches here under the matching activeApp + generationSerial
            // guard, so no newer suggestion is being clobbered.
            completion = nil
            overlay.orderOut(nil)
            return
        }
        let tail = InputSanitizer.contextTail(context)
        // Scalar gate, first of all: a suggestion carrying a control character, a
        // private-use glyph or a U+FFFD is not a completion, it is the model echoing
        // something broken out of its own context. Never show it, never log it.
        guard TextSanitizer.isClean(text) else {
            log("drop completion with disallowed scalars")
            completion = nil
            overlay.orderOut(nil)
            return
        }
        // The one suggestion we KNOW is unwanted: the exact text the user just dismissed
        // with Esc, or typed straight past, for this exact context. Decoding is greedy, so
        // regenerating from an unchanged context reproduces it character for character and
        // it would pop back up the moment the debounce fired again.
        if InputSanitizer.isRepeatOfRejected(lastRejected, contextTail: tail, suggestion: text) {
            log("drop completion already rejected for this context")
            completion = nil
            overlay.orderOut(nil)
            return
        }
        // The confidence gate: when the model was mostly guessing, show nothing.
        // (A streamed partial of this generation may already be painted — take it
        // down rather than leave a known-low-quality suggestion up.)
        if let conf, conf < effectiveMinConfidence {
            dlog("[\(activeAppKey)] suppressed low-confidence completion conf=\(String(format: "%.2f", conf)) bar=\(String(format: "%.2f", effectiveMinConfidence))")
            noteSuppressed(context: context, suggestion: text, conf: conf)
            completion = nil
            overlay.orderOut(nil)
            return
        }
        // Drop completions that just repeat the text after the caret (showing only a
        // partial mid-word remainder would be confusing) — regenerate instead.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !lastTrailing.isEmpty, !trimmed.isEmpty,
           lastTrailing.hasPrefix(String(trimmed.prefix(min(trimmed.count, 12)))) {
            log("drop completion repeating trailing text"); completion = nil; overlay.orderOut(nil); return
        }
        let chars = Array(text)
        // What did the user type since the request? Robust to the 4000-char cap
        // front-truncating the buffer or an idle-reset clearing it: match on a
        // trailing anchor of the request-time buffer instead of a full hasPrefix.
        let typedSince: [Character]
        if buffer == requestedBuffer {
            typedSince = []
        } else {
            let anchor = String(requestedBuffer.suffix(80))
            if anchor.count >= 8, let r = buffer.range(of: anchor, options: .backwards) {
                typedSince = Array(buffer[r.upperBound...])
            } else if buffer.hasPrefix(requestedBuffer) {
                typedSince = Array(buffer.dropFirst(requestedBuffer.count))
            } else {
                scheduleGenerate(); return     // genuinely diverged — start over
            }
        }
        if typedSince.isEmpty {
            completion = ActiveCompletion(chars: chars)
        } else if typedSince.count < chars.count, Array(chars[0..<typedSince.count]) == typedSince {
            var comp = ActiveCompletion(chars: chars); comp.consumed = typedSince.count
            completion = comp
        } else {
            scheduleGenerate(); return         // typed off the prediction
        }
        stats.shown += 1; statsTouched()
        lastPresentedTail = tail
        lastPresentedAt = Date()
        noteTraining(context: context, suggestion: text, conf: conf, source: "generate")
        showCompletionRemainder(animate: true)
        calibAnchor = lastCaretPoint; calibPredicted = 0   // fresh calibration epoch
        maybePrefetch()
    }
}
