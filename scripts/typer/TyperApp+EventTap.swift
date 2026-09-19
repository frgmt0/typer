import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

extension TyperApp {
    func setupEventTap() {
        let disableMask = (1 << CGEventType.tapDisabledByTimeout.rawValue) | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        // Observer: listen-only at the head. Listen-only taps do NOT gate event
        // delivery on the callback returning, so a slow main thread can never stall
        // global keystrokes in other apps. This watches typing and builds state.
        let observerMask = (1 << CGEventType.keyDown.rawValue) |
                           (1 << CGEventType.leftMouseDown.rawValue) |
                           (1 << CGEventType.rightMouseDown.rawValue) |
                           (1 << CGEventType.otherMouseDown.rawValue) |
                           disableMask
        let observerCB: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<TyperApp>.fromOpaque(refcon!).takeUnretainedValue().observe(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        observerTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: CGEventMask(observerMask),
                                        callback: observerCB, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let observerTap else {
            log("ERROR observer tap creation failed; Accessibility permission likely missing for Typer.app")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, observerTap, 0), .commonModes)
        CGEvent.tapEnable(tap: observerTap, enable: true)

        // Accept tap: a consuming .defaultTap at the tail that only grabs Tab/backtick.
        // It is enabled ONLY while a suggestion is visible (refreshAcceptTap), so when
        // nothing is showing Typer consumes no keys at all.
        let acceptMask = (1 << CGEventType.keyDown.rawValue) | disableMask
        let acceptCB: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<TyperApp>.fromOpaque(refcon!).takeUnretainedValue().accept(type: type, event: event)
        }
        acceptTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                      options: .defaultTap, eventsOfInterest: CGEventMask(acceptMask),
                                      callback: acceptCB, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let acceptTap {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, acceptTap, 0), .commonModes)
            CGEvent.tapEnable(tap: acceptTap, enable: false)   // off until a suggestion shows
        }
        log("event taps installed (observer + accept)")
    }

    // Enable the consuming accept tap exactly while a suggestion is on screen.
    // Idempotent: each CGEvent.tapEnable is a BLOCKING mach round-trip to the
    // WindowServer, so calling it redundantly (e.g. on every tapDisabled echo) burns a
    // whole CPU core. Only touch the tap when the desired state actually changes.
    func refreshAcceptTap() {
        guard let acceptTap else { return }
        let want = completion != nil || active != nil || Date() < acceptGraceUntil
        if want == acceptTapEnabled { return }
        acceptTapEnabled = want
        CGEvent.tapEnable(tap: acceptTap, enable: want)
    }

    // Hold the accept tap open briefly after an accept exhausts the suggestion. Without
    // this, the tap tears down the instant completion=nil, and the second of two rapid
    // Tabs leaks to the host app — tabbing focus out of the field or inserting a literal
    // tab right where the user was accepting words. The trailing refresh releases the
    // tap once the grace expires (nothing else fires refreshAcceptTap on a timer).
    func armAcceptGrace(_ interval: TimeInterval = 0.35) {
        acceptGraceUntil = Date().addingTimeInterval(interval)
        refreshAcceptTap()
        DispatchQueue.main.asyncAfter(deadline: .now() + interval + 0.05) { [weak self] in
            self?.refreshAcceptTap()
        }
    }

    private func reEnable(_ tap: CFMachPort?, _ label: String) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        log("\(label) tap re-enabled")
    }

    // A mouse click is a cursor/focus change, not typing. Clear anything pending,
    // invalidate in-flight generations, and warm the context cache after the target
    // app has processed the click — but never schedule a completion from the click.
    // A left-click also places the text caret at the click point; record it as a cheap
    // caret seed for AX-hostile fields (see the caret probe's click-anchor tier).
    func handlePointerInteraction(at location: CGPoint? = nil) {
        if cfg.clickCaretEnabled, let location { recordClickCaret(at: location) }
        // The caret is wherever the click put it, so nothing typed before it is contiguous
        // with the caret any more. Everything after it is.
        typedSinceNav = ""
        invalidateAndResync()
        // A click usually moves keyboard focus too. Keep the anchor we just recorded —
        // it IS this click's caret placement.
        refreshObservedElement(dropClickAnchor: false)
    }

    // Shared "the text changed underneath us" path: a click moved the cursor, or a
    // ⌘V/⌘X/⌘Z mutated the field outside our keystroke view. Duck out instantly
    // (the ghost must never sit over text we did not predict), then re-sync the
    // buffer from AX once the host app has applied the change.
    //
    // `recordOutcome: false` is the caret-navigation entry point: the suggestion still
    // has to come down, but moving the cursor is not a verdict on it (see
    // `clearSuggestion(recordOutcome:)`). A click keeps the old behaviour and records.
    // `navInitiated: true` is the keyboard/AX caret-move path (an arrow key, a chord, an
    // external selection change). It is the one case where the user may have carried on
    // typing between the caret move and this re-sync, and that typing has to survive it —
    // see the `reconcile` branch.
    func invalidateAndResync(recordOutcome: Bool = true, navInitiated: Bool = false) {
        syncActiveApp()
        // What the user typed since the caret moved: contiguous, known-good text sitting
        // immediately before the caret right now.
        let typedSince = navInitiated ? typedSinceNav : ""
        // A nav re-sync the user has already typed past is a buffer RECONCILIATION, not an
        // invalidation. `scheduleCaretResync` deliberately defers until the typing pause, so
        // by the time it runs the typing has re-established where the caret is, has driven
        // its own generations, and may have a suggestion on screen — and tearing all of that
        // down (bumping the serial, cancelling the debounce, clearing the suggestion) is why
        // there was never a suggestion at the first pause after ANY caret move, i.e. in the
        // whole of mid-text editing. Reconciliation only re-reads the buffer; the teardown
        // still happens below if the AX text turns out to disagree with what we watched the
        // user type.
        let reconcile = !typedSince.isEmpty
        if !reconcile {
            generationSerial &+= 1
            debounce?.invalidate(); debounce = nil
            clearSuggestion(recordOutcome: recordOutcome)
            lastTrailing = ""
            lastRejected = nil          // the caret moved: a different context entirely
            lastPresentedTail = ""
            // The text moved under us (click / paste / undo): every cached caret coordinate
            // and font is stale. Keep the click anchor — it was recorded moments ago and is
            // stamped to the resynced app below.
            invalidateCaret(reason: "resync", dropClickAnchor: false)
            recordLearning()
        }
        // Until the read below lands, the buffer still describes text at the OLD caret
        // position. generate() therefore prompts from `typedSinceNav` alone in this window —
        // that is what makes it impossible for stale text to be glued to text typed
        // somewhere else.
        navResyncPending = true
        let serial = generationSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            // Clear the click-pending flag in every exit path. If typing raced in before
            // this resync (serial advanced), the buffer was never reset, so a click anchor
            // can't be baselined coherently — abandon it rather than leave a half-stamped
            // one that would misplace the ghost.
            let clickPending = self.clickCaretPending
            self.clickCaretPending = false
            guard self.generationSerial == serial else {   // typing happened; leave it alone
                if clickPending { self.clickCaretPoint = nil; self.clickCaretApp = "" }
                // The buffer still has not been reconciled, and nothing else would ever come
                // back for it — leaving `navResyncPending` set would clamp the prompt to
                // `typedSinceNav` for the rest of the session. Try again after this burst.
                self.scheduleCaretResync()
                return
            }
            self.navResyncPending = false
            self.syncActiveApp()
            // Reconciliation skipped the up-front flush (the non-reconcile path already ran
            // it): the text typed since the caret moved is about to be replaced by the
            // host's own, so learn from it while it is still attributable. Watermarked, so
            // this costs nothing when there is no delta.
            if reconcile { self.recordLearning() }
            // AX text arrives with whatever invisible formatting the host app keeps in
            // its value (BOMs, bidi marks). Strip it here so it never reaches the buffer,
            // and therefore never the prompt or a store.
            if let ax = self.textAroundCursor(limit: 500) {
                let before = TextSanitizer.strippingInvisibles(ax.before)
                // Does the host agree that the text we watched the user type is sitting
                // right before the caret? If it does, the suggestion on screen was built on
                // solid ground and must not be flashed off and back on. If it does NOT,
                // something else moved or rewrote the text and the full teardown is owed
                // after all.
                let agrees = reconcile && before.hasSuffix(typedSince)
                if reconcile && !agrees { self.tearDownForDisagreeingResync() }
                // Resynced text was NOT necessarily typed by this user (it is whatever the
                // host had in the field), so the whole of it is marked unlearnable — see
                // `adoptResyncedBuffer`.
                self.adoptResyncedBuffer(before.isEmpty ? "" : String(before.suffix(500)),
                                         keepSuggestionMemory: agrees)
            } else if reconcile {
                // AX cannot answer (a terminal, an Electron shell with no text, an AXValue
                // past the 20k cap). We do not know the text before the caret — but we DO
                // know the characters typed since it moved, and they are contiguous with it.
                // Keeping exactly those, and nothing older, is the honest buffer: the stale
                // pre-navigation text (which is what used to be glued onto them) is dropped,
                // and in AX-hostile apps the keystroke buffer is not wiped out from under the
                // only prompt source there is.
                self.truncateBufferFront(keeping: typedSince.count)
            } else {
                // No AX answer and nothing typed since: we genuinely do not know where the
                // caret is or what precedes it, and an empty buffer is the honest state.
                self.resetBuffer()
            }
            self.saveActiveAppState()
            self.resolveCaret()
            // If this resync followed a fresh left-click (pending flag), stamp the click
            // anchor to the just-synced active app, baselined at the current buffer length
            // so typed-width extrapolation starts from zero. The flag (not a time window)
            // ensures a paste/⌘Z resync never re-baselines a stale anchor.
            if self.cfg.clickCaretEnabled, clickPending, self.clickCaretPoint != nil {
                self.clickCaretApp = self.activeAppKey
                self.clickCaretBufferLen = self.buffer.count
            }
            self.refreshBackgroundIfNeeded()
            // Deferred past a typing burst: the buffer is only now correct, and nothing else
            // would ask for a completion until the next keystroke. Generating was the one
            // thing this path never did, which is why a caret move cost the user a
            // suggestion for the whole of the pause that followed it — i.e. throughout
            // mid-text editing, the common case. The usual gates (secure field, disabled
            // app, snooze, minimum context, mid-line rules) all still apply inside generate().
            // A suggestion the host's text just confirmed stays as it is — regenerating would only swap it under the user.
            if reconcile, self.completion == nil, self.active == nil { self.scheduleGenerate() }
        }
    }

    // The re-sync found the host's text disagreeing with what we watched the user type:
    // something else moved the caret or rewrote the field while they were typing. The
    // reconciliation is off, and the full invalidation we skipped is owed after all.
    func tearDownForDisagreeingResync() {
        generationSerial &+= 1
        debounce?.invalidate(); debounce = nil
        clearSuggestion(recordOutcome: false)   // not the user's verdict on the suggestion
        lastTrailing = ""
        lastRejected = nil
        lastPresentedTail = ""
        invalidateCaret(reason: "resync disagreed", dropClickAnchor: false)
        // No recordLearning() here: the caller has already flushed what was typed, and
        // flushing twice would only advance watermarks that are already current.
    }

    // Listen-only: observes typing, builds the buffer, drives generation. Never
    // consumes Tab/backtick (the accept tap does that).
    func observe(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { reEnable(observerTap, "observer"); return }
        if IsSecureEventInputEnabled() {                 // never capture during secure input
            if completion != nil || active != nil { clearSuggestion() }
            return
        }
        // Secure FIELD gate (spec D.3): catches password/concealed fields that don't trip
        // the process-wide secure-input flag (non-secure-input password fields, secure web
        // fields). The AX read is bounded (AXSafe) and only taken while a suggestion is on
        // screen — the path where we MUST duck out — so the idle keystroke path stays free
        // of a per-key IPC round-trip. `generate()` independently re-checks via isAppDisabled.
        if completion != nil || active != nil,
           let el = focusedElement(), focusedFieldIsSecure(el) {
            clearSuggestion()
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
            // Our own insertion. Stamp the time: the host app will post an
            // AXSelectedTextChanged a moment later, and the observer has to know that one
            // was caused by us rather than by something moving the caret behind our back.
            lastSyntheticAt = Date()
            return
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            // Only a left-click reliably places the text caret; right/other clicks open
            // menus and shouldn't seed a caret anchor.
            handlePointerInteraction(at: type == .leftMouseDown ? event.location : nil)
            return
        }
        guard type == .keyDown else { return }
        syncActiveApp()
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // event.flags already carries the live modifier state for this keyDown, so we
        // don't track Shift/Command/Control/Option ourselves (and the observer tap no
        // longer needs keyUp events at all).
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // A selection only changes what ⌫ means, and resolving it costs TWO synchronous AX
        // reads, so it is resolved for that one keycode and nowhere else — and not even
        // always there. A held ⌫ emits a keyDown every ~30 ms and each of those repeats
        // would pay the round-trip; the first press of the run already resolved (and, if
        // there was a selection, deleted) it, so every repeat after it is by construction a
        // plain one-character delete. An empty buffer has nothing for ⌫ to mirror and
        // nothing left to protect, so it does not buy the read either.
        let selection = (code == InputSanitizer.backspaceKey && !isRepeat && !buffer.isEmpty)
            ? selectionIsNonEmpty() : false

        switch InputSanitizer.classify(keycode: code, flags: flags, chars: event.keyboardString,
                                       isRepeat: isRepeat, selectionNonEmpty: selection) {

        case .accept:
            // Tab is the accept tap's, always. Backtick is only an accept while something
            // is on screen for it to accept — otherwise it is a character being typed.
            if code == InputSanitizer.backtickKey, completion == nil, active == nil,
               let chars = event.keyboardString, TextSanitizer.isClean(chars) {
                dlog("[\(activeAppKey)] key code=\(code)")
                handleTyping(chars, isRepeat: isRepeat)
            }
            return

        case .dismiss:
            // Esc (or keypad Clear) with a suggestion showing is an explicit rejection —
            // feed it back, and remember it so an identical regeneration for the identical
            // context doesn't put it straight back on screen.
            //
            // The serial bump and the debounce cancel are the other half of that promise.
            // Without them a request already in the helper landed ~200 ms later, walked
            // straight through presentCompletion's serial guard, and put the dismissed
            // suggestion back up — with its outcome recorded a second time, against a
            // suggestion the user had already said no to. Esc means stop: nothing this
            // generation produces may reach the screen, and no queued generation may fire.
            generationSerial &+= 1
            debounce?.invalidate(); debounce = nil
            if let comp = completion {
                lastRejected = InputSanitizer.RejectedSuggestion(contextTail: lastPresentedTail,
                                                                text: String(comp.chars))
                resolveCompletionOutcome(comp, via: "none")
            }
            rejectActiveTypo()      // a dismissed spelling fix: count it, optionally stop re-suggesting
            clearSuggestion(); return

        case .backspace:
            // A plain ⌫ with no selection: exactly one character came off the end, which
            // is the one deletion the buffer can mirror on its own.
            generationSerial &+= 1
            lastUserTypedAt = Date()
            if !buffer.isEmpty {
                buffer.removeLast()
                // The character that came off may have been one the user typed since the
                // caret last moved — the tail the pending re-sync would fall back to.
                if !typedSinceNav.isEmpty { typedSinceNav.removeLast() }
                // The tail may have been inside a span; clip so the bookkeeping cannot
                // point past the end of the buffer.
                clipUnlearnableSpans()
            }
            saveActiveAppState(); clearSuggestion(); scheduleGenerate(); return

        case .submit:
            generationSerial &+= 1
            lastUserTypedAt = Date()
            if flags.contains(.maskShift) { push("\n", countsAsUserTyping: false) } else {
                recordLearning()
                resetBuffer()
                saveActiveAppState(); clearSuggestion()
            }
            return

        case .navigation, .edit:
            // The caret moved, or text was removed in a way the buffer cannot mirror.
            // Nothing is typed here: no character is buffered, `lastUserTypedAt` is NOT
            // bumped (so this can never re-arm a generation as if it were a keystroke),
            // and the suggestion comes down WITHOUT being recorded as a rejection.
            dismissForExternalEdit(reason: "caret/edit key \(code)")
            return

        case .command:
            // ⌘V/⌘X/⌘Z mutate the field's text outside our keystroke view; ⌘A, ⌘←/→,
            // ⌃A/⌃E/⌃K, ⌘⇧Z and friends move the caret or rewrite the line. Either way the
            // buffer is now wrong and the ghost would sit stale on top of the result, so
            // every chord we do not recognise as inert gets the same duck-out + re-sync.
            if InputSanitizer.isHarmlessChord(keycode: code, flags: flags) { return }
            dlog("[\(activeAppKey)] chord code=\(code) — resync")
            dismissForExternalEdit(reason: "chord \(code)")
            return

        case .ignore:
            return

        case .text(let chars):
            dlog("[\(activeAppKey)] key code=\(code)")
            handleTyping(chars, isRepeat: isRepeat)
        }
    }

    // Does the focused field currently hold a selection? Only consulted for ⌫, where it
    // decides between "one character came off the end" and "a whole selection went away".
    // Bounded (AXSafe's 50 ms messaging timeout) and never taken while our own UI is
    // frontmost, where an AX read would walk a SwiftUI a11y tree on the main thread.
    func selectionIsNonEmpty() -> Bool {
        guard !frontmostIsSelf, let element = focusedElement() else { return false }
        guard let value = axRead(element, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return false }
        return range.length > 0
    }

    // Keep the unlearnable-span bookkeeping inside the buffer after a plain backspace.
    // A span the deletion ate into keeps only the part that is still there.
    func clipUnlearnableSpans() {
        let count = buffer.count
        // Both watermarks are offsets into the buffer too, and the deletion just made the
        // buffer shorter than they are. Clamping them here (rather than only where they are
        // read) keeps every index that points into the buffer consistent at all times.
        if let w = lexiconWatermark[activeAppKey], w > count { lexiconWatermark[activeAppKey] = count }
        if let w = styleWatermark[activeAppKey], w > count { styleWatermark[activeAppKey] = count }
        guard let spans = unlearnableSpans[activeAppKey], !spans.isEmpty else { return }
        unlearnableSpans[activeAppKey] = spans.compactMap { span in
            guard span.start < count else { return nil }
            guard span.end > count else { return span }
            return UnlearnableSpan(start: span.start, text: String(span.text.prefix(count - span.start)),
                                   source: span.source)
        }
    }

    // A caret move or an unmodelled edit: take the ghost down at once (it must never sit
    // over text we did not predict) and schedule ONE debounced re-sync. No outcome is
    // recorded — navigation is not a judgement — and nothing here counts as typing.
    func dismissForExternalEdit(reason: String) {
        generationSerial &+= 1
        debounce?.invalidate(); debounce = nil
        clearSuggestion(recordOutcome: false)
        lastTrailing = ""
        lastRejected = nil
        lastPresentedTail = ""
        // The caret is now somewhere we cannot model, so nothing already in the buffer is
        // known to sit in front of it any more. Everything typed from here IS, and that is
        // the buffer the re-sync falls back to when the app can't answer. Setting the flag
        // here (not only in `invalidateAndResync`) covers the debounce window too, so a
        // completion generated between the arrow key and the re-sync is never prompted from
        // text at the old caret position glued to text typed at the new one.
        typedSinceNav = ""
        navResyncPending = true
        invalidateCaret(reason: reason, dropClickAnchor: true)
        scheduleCaretResync()
    }

    // Trailing-edge debounce for the AX re-sync. A held ← emits a keyDown every ~30 ms;
    // each one must NOT cost an AX round-trip, so the re-sync fires once, after the key
    // has settled. Re-arms itself while events keep arriving, and also while the user is
    // actively typing — an arrow key followed by a burst of typing should re-sync when the
    // burst ends, not in the middle of it (where `invalidateAndResync`'s own serial guard
    // would abandon it anyway).
    func scheduleCaretResync() {
        caretResyncLastAt = Date()
        guard !caretResyncScheduled else { return }
        caretResyncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + TyperApp.caretResyncDebounce) { [weak self] in
            guard let self else { return }
            self.caretResyncScheduled = false
            let quiet = TyperApp.caretResyncDebounce - 0.02
            if Date().timeIntervalSince(self.caretResyncLastAt) < quiet ||
               Date().timeIntervalSince(self.lastUserTypedAt) < quiet {
                self.scheduleCaretResync()      // still moving / still typing: wait for the pause
                return
            }
            self.invalidateAndResync(recordOutcome: false, navInitiated: true)
        }
    }

    // Consuming tap, enabled only while a suggestion is visible: grabs Tab/backtick.
    func accept(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-arm ONLY if a suggestion is actually showing. A tapDisabled notification
        // while nothing is up is our own tapEnable(false) echoing back — re-enabling
        // here (a blocking mach call) would spin a whole CPU core indefinitely.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if completion != nil || active != nil || Date() < acceptGraceUntil {
                acceptTapEnabled = true
                if let acceptTap { CGEvent.tapEnable(tap: acceptTap, enable: true) }
            } else {
                acceptTapEnabled = false
            }
            return nil
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker { return Unmanaged.passUnretained(event) }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if code == CGKeyCode(kVK_Tab) {
            if acceptCompletionWord() { return nil }
            if acceptOneWord() { return nil }
            // A Tab in the grace window right after an accept exhausted the suggestion
            // is the user asking for MORE, not a focus change — swallow it. Keep the
            // window open while the next chunk is actually on its way, so Tab-mashing
            // through a generation never tabs out of the field.
            if Date() < acceptGraceUntil {
                if requestInFlight || (debounce?.isValid ?? false) { armAcceptGrace() }
                return nil
            }
        } else if code == CGKeyCode(kVK_ANSI_Grave) {
            if acceptCompletionAll() { return nil }
            if acceptAll() { return nil }
        }
        return Unmanaged.passUnretained(event)
    }

    // Core "type as fast as you think" path. The user's keystroke passes through to
    // the app regardless; here we decide whether it matches the live prediction
    // (keep it, just shrink the ghost) or deviates (regenerate).
    func handleTyping(_ text: String, isRepeat: Bool = false) {
        generationSerial &+= 1
        lastUserTypedAt = Date()
        acceptGraceUntil = .distantPast   // typed a real character — moved on; a Tab now is a real Tab
        // A held key really types, so it goes in the buffer; it is just not vocabulary.
        unlearnableSource = .autoRepeat
        appendToBuffer(text, learnable: InputSanitizer.textIsLearnable(isRepeat: isRepeat))
        // Emoji completion (#7): a finished `:shortcode:` / emoticon expands in place, or a
        // `:prefix` surfaces a candidate. Consumes the event when handled (no LLM completion).
        // No-op unless cfg.emojiCompletionsEnabled. (review L1: was implemented but never called)
        if maybeHandleEmoji(text) { return }
        // A just-finished misspelled word takes priority over following a live
        // completion: typing the separator that ends "peopel" should surface the fix,
        // not get swallowed as "you typed along with the ghost". Only fires when the
        // word is actually misspelled, so correctly-spelled type-along is untouched.
        if cfg.typoEnabled, text.unicodeScalars.allSatisfy({ isWordSeparator($0) }),
           let word = lastWordFromBuffer(), let fix = correction(for: word) {
            // Resolve the on-screen completion's outcome before dropping it for the typo fix,
            // the same way the divergence path below does — otherwise its accept/reject signal
            // never reaches the model race, adaptive feedback, or training log, and its pending
            // training example is silently overwritten by the next suggestion (issue #3).
            if let comp = completion {
                resolveCompletionOutcome(comp, via: comp.consumed > 0 ? "typethrough" : "none")
                completion = nil; prefetched = nil; prefetchKey = ""; overlay.orderOut(nil)
            }
            presentTypo(word: word, fix: fix)
            return
        }
        // Grammar runs on sentence-terminating separators only (. ! ? newline), parallel
        // to the typo branch but lower priority (spelling fired first above). OFF by
        // default. The flagged span's exact AX range is resolved from the sentence's
        // UTF-16 offset, so apply() needs no backward word scan.
        if cfg.grammarEnabled, text.unicodeScalars.allSatisfy({ ".!?\n\r".unicodeScalars.contains($0) }) {
            if let ax = textAroundCursor(limit: 500), !ax.before.isEmpty {
                let before = ax.before as NSString
                // The sentence just completed: from the last sentence boundary to the caret.
                let sentence = lastSentence(in: ax.before)
                let startUTF16 = before.length - (sentence as NSString).length
                // Resolve the live completion's outcome before tearing it down for grammar,
                // exactly as the typo branch above does (issue #3): its accept/reject signal
                // must reach the race / feedback / training log, not be silently dropped.
                if let comp = completion {
                    resolveCompletionOutcome(comp, via: comp.consumed > 0 ? "typethrough" : "none")
                    completion = nil; prefetched = nil; prefetchKey = ""; overlay.orderOut(nil)
                }
                grammarCorrections(in: sentence, sentenceStartUTF16: startUTF16)
                // Detection is async; it presents only if nothing is showing. Fall through
                // so a completion can still be scheduled if grammar finds nothing.
            }
        }
        if let comp = completion {
            if followAlong(text) { return }   // typed exactly what we predicted — keep it
            // Deviated from the prediction: an implicit rejection (or partial use, if
            // some words were consumed first). Feed it back, then drop the prediction
            // and any speculative prefetch.
            //
            // Typing past a suggestion is also the second way a suggestion is turned down,
            // so remember it: the next generation from this same context would otherwise
            // decode the identical text and put it straight back.
            lastRejected = InputSanitizer.RejectedSuggestion(contextTail: lastPresentedTail,
                                                             text: String(comp.chars))
            resolveCompletionOutcome(comp, via: comp.consumed > 0 ? "typethrough" : "none")
            completion = nil
            prefetched = nil
            prefetchKey = ""
            overlay.orderOut(nil)
        }
        scheduleGenerate()
    }

    // Returns true if every character of `text` matched the next predicted
    // character, advancing the consumed prefix instead of regenerating.
    func followAlong(_ text: String) -> Bool {
        guard var comp = completion else { return false }
        for ch in text {
            guard comp.consumed < comp.chars.count, comp.chars[comp.consumed] == ch else { return false }
            comp.consumed += 1
        }
        completion = comp
        if comp.done {
            // Typed all the way through — a strong "this matched my intent" signal.
            stats.accepted += 1; statsTouched()
            resolveCompletionOutcome(comp, via: "typethrough")
            completion = nil
            if !promotePrefetch() { overlay.orderOut(nil); scheduleGenerate() }
        } else {
            // Move the ghost immediately by the measured width of what was typed (the
            // app hasn't applied the keystroke yet, so a synchronous AX read would be
            // stale and overlap). A coalesced deferred re-anchor then corrects drift
            // and line-wrap once the app has caught up.
            advanceGhost(by: text)
            showCompletionRemainder(reanchor: false)
            scheduleReanchor()
            maybePrefetch()
        }
        return true
    }
}
