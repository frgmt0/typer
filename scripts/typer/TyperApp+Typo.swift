import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

extension TyperApp {
    // MARK: - Typo correction (NSSpellChecker)

    // The word just before the caret, taken from the cheap keystroke buffer. This
    // runs on every word-separator keystroke, so it MUST stay cheap — reading the
    // full focused-element AXValue here would copy hundreds of KB in terminals/
    // editors on each space. The exact AX range for replacement is computed lazily,
    // only when the user actually accepts a correction (see typoRangeViaAX).
    func lastWordFromBuffer() -> String? {
        var chars: [Unicode.Scalar] = []
        for sc in buffer.unicodeScalars.reversed() {
            if isWordSeparator(sc) { if chars.isEmpty { continue } else { break } }
            chars.append(sc)
        }
        let word = String(String.UnicodeScalarView(chars.reversed()))
        return word.isEmpty ? nil : word
    }

    // Locate `word` immediately before the caret in the focused element and return
    // its exact UTF-16 range plus the count of separator units between the word and
    // the caret (the space/punctuation the user just typed) so the caret can be
    // restored after them. Called only on accept, so the one big AXValue read is
    // acceptable. Returns nil for apps without a usable AXValue (keystroke fallback).
    func typoRangeViaAX(word: String) -> (element: AXUIElement, range: CFRange, trailing: Int)? {
        guard let element = focusedElement() else { return nil }
        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String, !value.isEmpty,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return nil }
        var sel = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &sel), sel.location > 0 else { return nil }
        let utf16 = Array(value.utf16)
        let caret = min(sel.location, utf16.count)
        var end = caret
        while end > 0, let sc = Unicode.Scalar(utf16[end - 1]), isWordSeparator(sc) { end -= 1 }
        var start = end
        while start > 0, let sc = Unicode.Scalar(utf16[start - 1]), !isWordSeparator(sc) { start -= 1 }
        guard end > start else { return nil }
        let units = Array(utf16[start..<end])
        guard String(utf16CodeUnits: units, count: units.count) == word else { return nil }
        return (element, CFRange(location: start, length: end - start), caret - end)
    }

    // Returns the spell-corrected form of a word, or nil if it is correct / not a
    // candidate. Uses the same engine macOS itself uses — local, instant, accurate.
    func correction(for word: String) -> String? {
        guard word.count >= 3, word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
        // Skip likely-intentional all-caps acronyms (NASA, JSON, ...).
        if word.allSatisfy({ $0.isUppercase }) { return nil }
        let checker = NSSpellChecker.shared
        let lang = checker.language()
        let full = NSRange(location: 0, length: (word as NSString).length)
        // Autocorrect first: correction() returns nil for correct words (so no
        // false positives on "hello"/"NASA") but still catches common typos that
        // checkSpelling does not flag, e.g. "teh" -> "the". This is the highest-trust
        // source; when casing fixes are enabled it may differ only by case (i -> I).
        if let c = checker.correction(forWordRange: full, in: word, language: lang, inSpellDocumentWithTag: spellTag) {
            if c.lowercased() != word.lowercased() { return c }
            // Case-only fix (i -> I, proper nouns): trust it only from this autocorrect
            // pass, and only when explicitly enabled — guesses are too noisy for case.
            if cfg.typoCasingFix, c != word { return c }
        }
        // Otherwise only offer a guess when the word is genuinely flagged.
        let mis = checker.checkSpelling(of: word, startingAt: 0)
        guard mis.location != NSNotFound, mis.length > 0 else { return nil }
        guard let raw = checker.guesses(forWordRange: full, in: word, language: lang, inSpellDocumentWithTag: spellTag),
              !raw.isEmpty else { return nil }
        let candidates = raw.filter { $0.lowercased() != word.lowercased() }
        guard !candidates.isEmpty else { return nil }
        // Pick the best guess, not blindly the first. Ranking + a confidence gate are
        // both opt-in; with both off this stays byte-for-byte the old `.first` behavior.
        let best = cfg.typoRankingEnabled ? rankGuesses(candidates, for: word) : candidates[0]
        if cfg.typoMinConfidence > 0 {
            let norm = Double(editDistance(word.lowercased(), best.lowercased())) / Double(max(word.count, best.count, 1))
            // A larger normalized edit distance means a less-confident guess; reject
            // those (suppresses low-confidence leaps like "rcv" -> "receive").
            if norm > (1 - cfg.typoMinConfidence) { return nil }
        }
        return best
    }

    // Order spell-checker guesses by how plausibly they're the word the user meant:
    // smaller edit distance first, then a bonus when a single substitution is a QWERTY
    // neighbor (a fat-finger), then the user's own frequency as the tie-breaker — a
    // word they actually type wins over an equidistant one they don't.
    func rankGuesses(_ guesses: [String], for word: String) -> String {
        let w = word.lowercased()
        let topList = cfg.lexiconEnabled ? Set(lexicon.topWords().split(separator: " ").map(String.init)) : []
        func score(_ g: String) -> Double {
            let lg = g.lowercased()
            var s = Double(editDistance(w, lg))                 // lower is better
            if lg.count == w.count, isSingleQwertySub(w, lg) { s -= 0.5 }
            if topList.contains(lg) { s -= 0.25 }               // user types this word
            return s
        }
        return guesses.min { score($0) < score($1) } ?? guesses[0]
    }

    // True when two equal-length strings differ in exactly one position and that pair
    // of letters are physically adjacent on a QWERTY keyboard (a likely fat-finger typo).
    func isSingleQwertySub(_ a: String, _ b: String) -> Bool {
        let ca = Array(a), cb = Array(b)
        guard ca.count == cb.count else { return false }
        var diffIdx = -1
        for i in ca.indices where ca[i] != cb[i] {
            if diffIdx >= 0 { return false }     // more than one difference
            diffIdx = i
        }
        guard diffIdx >= 0 else { return false }
        return TyperApp.qwertyNeighbors[ca[diffIdx]]?.contains(cb[diffIdx]) ?? false
    }

    static let qwertyNeighbors: [Character: Set<Character>] = {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        var map: [Character: Set<Character>] = [:]
        let grid = rows.map { Array($0) }
        for (r, row) in grid.enumerated() {
            for (c, ch) in row.enumerated() {
                var n = Set<Character>()
                if c > 0 { n.insert(row[c - 1]) }
                if c + 1 < row.count { n.insert(row[c + 1]) }
                if r > 0, c < grid[r - 1].count { n.insert(grid[r - 1][c]) }
                if r + 1 < grid.count, c < grid[r + 1].count { n.insert(grid[r + 1][c]) }
                map[ch] = n
            }
        }
        return map
    }()

    // Plain Levenshtein distance (insert/delete/substitute = 1). Small inputs (words),
    // so the simple two-row DP is plenty.
    func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }

    // Show the inline correction diff. Builds a `.spelling` Correction for a known
    // misspelling; the general present(_:) drives the overlay (grammar uses it too).
    // Honors the "Show suggested fixes" setting (#8): when off, Typer still SUPPRESSES on a
    // suspected typo (if that gate is on) but doesn't draw the strike→green diff inline.
    func presentTypo(word: String, fix: String) {
        guard cfg.showSuggestedFixes else { return }
        present(Correction(kind: .spelling, displayOriginal: word, replacement: fix, message: nil, axRange: nil))
    }

    // Present any pending correction inline at the caret line, same as completions.
    func present(_ c: Correction) {
        // No caret fix means we'd have to guess where the diff belongs. A correction has
        // no re-place path (unlike a completion, which reappears on the next fix), so
        // rather than draw it in the wrong place we don't arm it at all.
        guard let fix = resolveCaret(forceFresh: true) else {
            dlog("[\(activeAppKey)] \(c.kind) '\(c.displayOriginal)' suppressed — no caret fix")
            return
        }
        active = c
        stats.shown += 1; statsTouched()
        overlay.show(correction: c, at: fix)
        dlog("[\(activeAppKey)] \(c.kind) '\(c.displayOriginal)' -> '\(c.replacement ?? c.message ?? "")' at=\(fix.pointAppKit)")
    }

    // Apply a correction in place. Prefers AX (exact range, preserves the trailing
    // separator); falls back to keystroke selection for apps without AX write support.
    // Spelling resolves its span lazily (word scan before the caret); grammar already
    // carries an absolute axRange, so it skips the scan. The big AXValue read happens
    // here, only on accept.
    func apply(_ c: Correction) {
        guard let text = c.replacement else { return }   // advisory-only: nothing to apply
        let original = c.displayOriginal
        // Grammar: span already known. Spelling: locate the word before the caret.
        let resolved: (element: AXUIElement, range: CFRange, trailing: Int)? =
            c.axRange != nil ? axRangeForSpan(c.axRange!) : typoRangeViaAX(word: original)
        if let r = resolved {
            // Electron/WebKit contenteditables often claim AX selection writes worked
            // but then insert at the live caret instead of replacing the selected word
            // (e.g. "this" -> "ththeis"). For those shells, use AX only to put the caret
            // at the known end position, then do the keystroke deletion/paste path that
            // they actually honor. (This used to probe TextMarker bounds per apply; the
            // frontmost app's kind is now classified once and cached.)
            let webLike = isWebContentElement(r.element)
            if !webLike,
               setAXText(element: r.element, range: r.range, text: text, trailing: r.trailing, original: original) {
                replaceLastWordInBuffer(original: original, with: text)
                log("\(c.kind) replaced via AX")
                return
            }
            _ = setAXCaret(element: r.element, location: r.range.location + r.range.length + r.trailing)
            replaceWordBeforeSeparatorViaKeys(original: original, with: text, trailing: r.trailing)
            replaceLastWordInBuffer(original: original, with: text)
            log("\(c.kind) replaced via keystrokes")
        } else {
            replaceWordBeforeSeparatorViaKeys(original: original, with: text)
            replaceLastWordInBuffer(original: original, with: text)
            log("\(c.kind) replaced via keystrokes")
        }
    }

    // Resolve a known absolute UTF-16 span in the focused element (grammar already
    // computed it), without the backward word scan typoRangeViaAX does for spelling.
    // trailing is 0: a grammar span is the exact flagged text, no trailing separator.
    func axRangeForSpan(_ range: CFRange) -> (element: AXUIElement, range: CFRange, trailing: Int)? {
        guard let element = focusedElement() else { return nil }
        return (element, range, 0)
    }

    // Replace `range` with `text` and leave the caret after the trailing separator.
    // Returns false (→ keystroke fallback) if the selection write didn't take: many
    // Electron/Chromium apps (Discord, Slack, VS Code) return .success for setting
    // kAXSelectedTextRange but silently ignore it, which would otherwise insert the
    // correction at the live caret instead of over the misspelled word. We read the
    // range back and only trust the AX path when the selection actually moved.
    func setAXText(element: AXUIElement, range: CFRange, text: String, trailing: Int, original: String) -> Bool {
        var r = range
        guard let rangeAx = AXValueCreate(.cfRange, &r),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeAx) == .success
        else { return false }
        var checkRef: CFTypeRef?
        var got = CFRange(location: 0, length: 0)
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &checkRef) == .success,
              let checkVal = checkRef,
              AXValueGetValue(checkVal as! AXValue, .cfRange, &got),
              got.location == range.location, got.length == range.length
        else { return false }   // selection didn't actually move — fall back to keystrokes
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }

        // If AXValue is readable, verify the replacement landed exactly where it was
        // supposed to. Some editors report success while inserting at a stale caret;
        // treating that as success is what produced strings like "ththeis".
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
           let value = valueRef as? String,
           range.location >= 0,
           range.location + (text as NSString).length <= value.utf16.count {
            let start = String.Index(utf16Offset: range.location, in: value)
            let end = String.Index(utf16Offset: range.location + (text as NSString).length, in: value)
            guard String(value[start..<end]) == text else { return false }
        }

        // Caret after the replacement and the separator(s) the user typed.
        _ = setAXCaret(element: element, location: range.location + (text as NSString).length + trailing)
        return true
    }

    func setAXCaret(element: AXUIElement, location: Int) -> Bool {
        var caret = CFRange(location: max(0, location), length: 0)
        guard let caretAx = AXValueCreate(.cfRange, &caret),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretAx) == .success
        else { return false }
        var checkRef: CFTypeRef?
        var got = CFRange(location: 0, length: 0)
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &checkRef) == .success,
              let checkVal = checkRef,
              AXValueGetValue(checkVal as! AXValue, .cfRange, &got)
        else { return false }
        return got.location == caret.location && got.length == 0
    }

    // Keystroke fallback for apps without usable AX text writes (Electron/Chromium:
    // Discord, Slack, VS Code). Deletes the misspelled word with Backspace rather
    // than selecting it — synthetic shift+arrow selection is silently dropped by
    // editors like Discord's ProseMirror, which would paste the fix at the word's
    // start instead of replacing it. Deletion and paste are both honored. `trailing`
    // defaults to 1: a single separator keystroke is what triggered the suggestion.
    func replaceWordBeforeSeparatorViaKeys(original: String, with text: String, trailing: Int = 1) {
        let wordLen = max(original.count, 1)
        let sepCount = max(trailing, 0)
        // The exact separator chars the user typed after the word (space/punct/newline). The
        // caret sits right after them, so we delete BACKWARD over the separators + the word and
        // re-insert "correction + same separators" in one paste — no LeftArrow/RightArrow dance.
        // The old arrow-based path raced with the host app and left a stray original character
        // (e.g. "alraedy " -> "aalready"); deleting monotonically from the caret can't misalign.
        let seps = String(buffer.suffix(sepCount))
        withPasteboard(text + seps) {
            for _ in 0..<(sepCount + wordLen) {            // delete trailing separator(s) + the misspelled word
                self.postKey(CGKeyCode(kVK_Delete)); usleep(9_000)
            }
            usleep(18_000)
            self.postPaste()                              // correction + the same separators; caret lands after
        }
    }

    func replaceLastWordInBuffer(original: String, with text: String) {
        if let r = buffer.range(of: original, options: .backwards) {
            buffer.replaceSubrange(r, with: text)
            saveActiveAppState()
        }
    }

    // Tab/backtick for the correction diff (completions are handled separately by
    // acceptCompletionWord / acceptCompletionAll). Advisory-only corrections (grammar
    // with no fix) are not applicable, so Tab falls through to the host app — there is
    // nothing to insert.
    func acceptOneWord() -> Bool {
        guard let active, active.applicable else { return false }
        apply(active)
        stats.accepted += 1; statsTouched()
        clearSuggestion()
        return true
    }

    // Explicit rejection of a spelling suggestion (Esc / dismissed): teach the spell
    // checker to stop re-suggesting it this session, and count it as ignored. No-op
    // unless learning-from-rejections is enabled. Grammar isn't fed back (range-based,
    // not word-based). Returns whether a spelling suggestion was actually rejected.
    @discardableResult
    func rejectActiveTypo() -> Bool {
        guard let active, active.kind == .spelling else { return false }
        stats.ignored += 1; statsTouched()
        if cfg.typoLearnFromRejections {
            NSSpellChecker.shared.ignoreWord(active.displayOriginal, inSpellDocumentWithTag: spellTag)
            dlog("[\(activeAppKey)] typo rejected, ignoring '\(active.displayOriginal)'")
        }
        return true
    }

    // Teach the spell checker the user's own vocabulary so their jargon/names stop being
    // flagged. Unconditional: it only REDUCES false positives. Called on lexicon updates.
    func syncLexiconToSpellChecker() {
        let words = lexicon.topWords(500).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return }
        NSSpellChecker.shared.setIgnoredWords(words, inSpellDocumentWithTag: spellTag)
    }

    // The trailing sentence of `text`: everything after the last sentence boundary
    // (. ! ? or newline) that precedes the end. Used to scope grammar checking to the
    // sentence the user just finished and to compute its UTF-16 offset in the field.
    func lastSentence(in text: String) -> String {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return "" }
        var start = 0   // no earlier boundary ⇒ the whole text is one sentence
        // Skip the trailing terminator(s) the user just typed, then walk back to the
        // boundary before them; the sentence begins just after it.
        var i = units.count - 1
        while i >= 0, let sc = Unicode.Scalar(units[i]), ".!?\n\r".unicodeScalars.contains(sc) { i -= 1 }
        while i >= 0 {
            if let sc = Unicode.Scalar(units[i]), ".!?\n\r".unicodeScalars.contains(sc) { start = i + 1; break }
            i -= 1
        }
        let slice = Array(units[start...])
        return String(utf16CodeUnits: slice, count: slice.count)
    }

    // MARK: - Grammar (NSSpellChecker text checking) — OFF by default behind cfg.grammarEnabled.

    // Detect grammar issues in `sentence` and present the first as a Correction. The
    // checking is async (requestChecking's completion handler), so presentation is
    // dispatched back to the main actor. `sentenceStartUTF16` is the UTF-16 offset of
    // the sentence within the focused field, used to build absolute AX spans for apply.
    // Grammar typically yields range + message with NO machine-applicable fix, so the
    // Correction is advisory-only (replacement == nil) — we never synthesize a fake fix.
    func grammarCorrections(in sentence: String, sentenceStartUTF16: Int) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return }
        let checker = NSSpellChecker.shared
        let ns = sentence as NSString
        let range = NSRange(location: 0, length: ns.length)
        let serial = generationSerial
        let appKey = activeAppKey
        checker.requestChecking(
            of: sentence, range: range,
            types: NSTextCheckingResult.CheckingType.grammar.rawValue,
            options: nil, inSpellDocumentWithTag: spellTag
        ) { [weak self] _, results, _, _ in
            // Build the first grammar correction off the main thread, then present it on
            // the main actor only if nothing changed underneath us (no new typing).
            guard let result = results.first(where: { $0.resultType == .grammar }) else { return }
            let flagged = ns.substring(with: result.range)
            // grammarDetails carries a per-issue message (NSGrammarUserDescription) and a
            // sub-range relative to the sentence; offset it into an absolute field span.
            let detail = result.grammarDetails?.first
            let message = detail?[NSGrammarUserDescription] as? String
            var subRange = result.range
            if let r = detail?[NSGrammarRange] as? NSValue { subRange = r.rangeValue }     // relative to sentence
            let absoluteLocation = sentenceStartUTF16 + subRange.location
            let axRange = CFRange(location: absoluteLocation, length: subRange.length)
            DispatchQueue.main.async {
                guard let self, appKey == self.activeAppKey, self.generationSerial == serial else { return }
                guard self.active == nil, self.completion == nil else { return }   // don't stomp a live suggestion
                self.present(Correction(kind: .grammar, displayOriginal: flagged,
                                        replacement: nil, message: message, axRange: axRange))
            }
        }
    }

    func acceptAll() -> Bool {
        // The only diff-style suggestion is typo; accepting all == accepting the word.
        return acceptOneWord()
    }

    // MARK: - Typo-suspicion gate (#8, spec E §8)

    // True when the word currently being typed looks misspelled, so the completion path
    // should NOT extend it (building on a likely mistake). Scoped to the CURRENT word only —
    // exactly like Cotypist's "only ever looks at the current word" caveat — via a single
    // NSSpellChecker.checkSpelling, cached per word so it isn't re-queried on every keystroke.
    //
    // Conservative: only flags words of 3+ letters made purely of letters/apostrophe, and
    // never flags a word the user's own lexicon contains (syncLexiconToSpellChecker already
    // teaches the checker their vocabulary, so jargon won't trip this). Returns false unless
    // `cfg.suppressCompletionOnTypoSuspected` is on, so it's free when the feature is off.
    func typoSuspectedInCurrentWord() -> Bool {
        guard cfg.suppressCompletionOnTypoSuspected else { return false }
        // Respect a per-app autocorrect-disabled override (the same field that gates fixes).
        let (bundle, _) = currentAppBundleAndName()
        if OverrideStore.shared.resolved(bundle: bundle).autocorrectDisabled == true { return false }
        guard let word = lastWordFromBuffer() else { return false }
        return SpellSuspicionCache.shared.isMisspelled(word, tag: spellTag)
    }

    // MARK: - Emoji completion (#7, spec E §7)

    // Whether emoji features are available in the current app: global flag AND not disabled
    // per-app via AppOverrides. `search` additionally requires its own flag/override.
    private func emojiCompletionAvailable() -> Bool {
        guard cfg.emojiCompletionsEnabled else { return false }
        let (bundle, _) = currentAppBundleAndName()
        if OverrideStore.shared.resolved(bundle: bundle).emojiCompletionsDisabled == true { return false }
        return true
    }
    private func emojiSearchAvailable() -> Bool {
        guard cfg.emojiSearchEnabled, emojiCompletionAvailable() else { return false }
        let (bundle, _) = currentAppBundleAndName()
        if OverrideStore.shared.resolved(bundle: bundle).emojiSearchDisabled == true { return false }
        return true
    }

    // Entry point for the keystroke path: after `text` was appended to the buffer, decide if
    // it completed an emoji trigger and, if so, handle it. Two modes (feature-mechanics §5):
    //   (a) inline expansion of a finished `:shortcode:` or a known ASCII emoticon — replace
    //       the typed token in place with the emoji;
    //   (b) `:prefix` search — surface a filtered candidate as the inline suggestion so Tab
    //       expands it (reuses the existing Correction/overlay machinery — no new wire type).
    // Returns true when it consumed the event (caller should not also schedule a completion).
    @discardableResult
    func maybeHandleEmoji(_ text: String) -> Bool {
        guard emojiCompletionAvailable() else { return false }
        // Only react on the keystroke that could finish a trigger: a colon (closes a
        // shortcode), or a separator that finishes an emoticon. A multi-char paste isn't a
        // trigger we own.
        guard let last = text.unicodeScalars.last else { return false }

        // (a1) finished `:shortcode:` — the buffer ends with `:name:`.
        if last == ":" , let expanded = pendingShortcodeExpansion() {
            applyEmojiExpansion(token: expanded.token, emoji: expanded.emoji)
            return true
        }
        // (a2) ASCII emoticon just completed by a separator (or the emoticon's own last char).
        if let em = pendingEmoticonExpansion(justTyped: text) {
            applyEmojiExpansion(token: em.token, emoji: em.emoji)
            return true
        }
        // (b) `:prefix` search — a colon-led partial of 2+ letters with no closing colon.
        if emojiSearchAvailable(), let s = pendingShortcodePrefix(), s.count >= 2 {
            let hits = EmojiData.shared.search(prefix: s, skinTone: cfg.emojiSkinTone, limit: 1)
            if let first = hits.first {
                // Present as a Tab-acceptable diff: the typed ":prefix" → the emoji. The token
                // starts with a colon (a separator), so the spelling word-scan can't relocate
                // it — carry the exact AX span so apply() takes the grammar-style span path.
                presentEmojiSearch(token: ":" + s, emoji: first.emoji)
                return true
            }
        }
        return false
    }

    // The `:name:` immediately before the caret in the buffer, resolved to its emoji (with
    // the user's skin tone applied). Returns the literal token (incl. colons) for replacement.
    private func pendingShortcodeExpansion() -> (token: String, emoji: String)? {
        // Buffer ends with the closing colon. Walk back to the opening colon.
        let scalars = Array(buffer.unicodeScalars)
        guard scalars.last == ":" else { return nil }
        var i = scalars.count - 2
        var name: [Unicode.Scalar] = []
        while i >= 0 {
            let sc = scalars[i]
            if sc == ":" {
                // Every scalar between the colons was validated as a name scalar on the way in.
                let raw = String(String.UnicodeScalarView(name.reversed()))
                guard !raw.isEmpty else { return nil }
                guard let emoji = EmojiData.shared.emoji(forShortcode: raw, skinTone: cfg.emojiSkinTone) else { return nil }
                return (":" + raw + ":", emoji)
            }
            if !isEmojiNameScalar(sc) { return nil }   // a non-name char before a colon ⇒ not a shortcode
            name.append(sc)
            i -= 1
        }
        return nil
    }

    // The `:prefix` partial before the caret (opening colon, letters, NO closing colon).
    private func pendingShortcodePrefix() -> String? {
        let scalars = Array(buffer.unicodeScalars)
        guard let last = scalars.last, isEmojiNameScalar(last) else { return nil }
        var i = scalars.count - 1
        var name: [Unicode.Scalar] = []
        while i >= 0 {
            let sc = scalars[i]
            if sc == ":" {
                // Require the colon to start a token (start of buffer or after a separator).
                if i == 0 || isWordSeparator(scalars[i - 1]) {
                    return String(String.UnicodeScalarView(name.reversed()))
                }
                return nil
            }
            if !isEmojiNameScalar(sc) { return nil }
            name.append(sc)
            i -= 1
        }
        return nil
    }

    // A known ASCII emoticon ending at the caret, e.g. ":)" or "<3". `justTyped` is the most
    // recent keystroke(s); we look back over the buffer up to the longest emoticon length and
    // return the longest token that is both a known emoticon AND sits on a token boundary.
    private func pendingEmoticonExpansion(justTyped: String) -> (token: String, emoji: String)? {
        let data = EmojiData.shared
        data.loadIfNeeded()
        guard data.maxEmoticonLength > 0 else { return nil }
        let scalars = Array(buffer.unicodeScalars)
        // Try longest tokens first so ":-)" beats a partial.
        for len in stride(from: min(data.maxEmoticonLength, scalars.count), through: 1, by: -1) {
            let tokenScalars = Array(scalars.suffix(len))
            let token = String(String.UnicodeScalarView(tokenScalars))
            guard let emoji = data.emoji(forEmoticon: token) else { continue }
            // Must sit on a boundary: the char before the token is a separator or buffer start.
            let beforeIdx = scalars.count - len - 1
            if beforeIdx < 0 || isWordSeparator(scalars[beforeIdx]) {
                return (token, emoji)
            }
        }
        return nil
    }

    private func isEmojiNameScalar(_ s: Unicode.Scalar) -> Bool {
        let c = Character(s)
        return c.isLetter || c.isNumber || c == "_" || c == "+" || c == "-"
    }

    // Replace the literal `token` (e.g. ":smile:" or ":)") that sits immediately before the
    // caret with `emoji`, in the field and in the buffer. Reuses the keystroke replace path
    // (no trailing separator — the user didn't type one; the token's own last char triggered).
    private func applyEmojiExpansion(token: String, emoji: String) {
        // Tear down any live completion first (this keystroke ended it).
        if let comp = completion {
            resolveCompletionOutcome(comp, via: comp.consumed > 0 ? "typethrough" : "none")
            completion = nil; prefetched = nil; prefetchKey = ""; overlay.orderOut(nil)
        }
        clearSuggestion()
        // Prefer an exact AX range replace; fall back to keystrokes. The token has no trailing
        // separator, so trailing = 0.
        if let r = emojiTokenRangeViaAX(token: token) {
            let webLike = isWebContentElement(r.element)
            if !webLike, setAXText(element: r.element, range: r.range, text: emoji, trailing: 0, original: token) {
                replaceTokenInBuffer(token: token, with: emoji)
                log("emoji expanded via AX '\(token)' -> \(emoji)")
                return
            }
            _ = setAXCaret(element: r.element, location: r.range.location + r.range.length)
        }
        replaceTokenBeforeCaretViaKeys(token: token, with: emoji)
        replaceTokenInBuffer(token: token, with: emoji)
        log("emoji expanded via keystrokes '\(token)' -> \(emoji)")
    }

    // Present a `:prefix` search hit as an inline, Tab-acceptable diff. Modeled on presentTypo
    // but carrying the literal `:prefix` token as the "original" so apply() locates and
    // replaces exactly it via the spelling word-scan path.
    private func presentEmojiSearch(token: String, emoji: String) {
        // Search results ARE the feature (gated upstream by emojiSearchAvailable), so they
        // present regardless of the typo-diff "Show suggested fixes" setting. We carry the
        // exact AX span of the `:prefix` token so apply() replaces precisely it via the
        // grammar-style span path — the spelling word-scan can't relocate a colon-led token.
        // If AX exposes no span for this field we fall back to the keystroke path with the
        // span set anyway: apply()'s span branch resolves it, and on failure drops to the
        // keystroke deletion of the original token's length (trailing 0 — no separator typed).
        guard let r = emojiTokenRangeViaAX(token: token) else {
            // No usable AXValue: emit it as a 0-trailing keystroke correction. Build a
            // synthetic span-less correction; apply()'s spelling branch will word-scan and
            // fail, then keystroke-replace — but for a colon-led token the scan won't match,
            // so present with a span-less correction would mis-replace. Skip search here; the
            // (a) inline `:shortcode:` expansion path (keystroke-safe) still covers this app.
            return
        }
        present(Correction(kind: .spelling, displayOriginal: token, replacement: emoji, message: nil, axRange: r.range))
    }

    // Exact UTF-16 range of `token` immediately before the caret in the focused element.
    private func emojiTokenRangeViaAX(token: String) -> (element: AXUIElement, range: CFRange, trailing: Int)? {
        guard let element = focusedElement() else { return nil }
        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String, !value.isEmpty,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return nil }
        var sel = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &sel), sel.location > 0 else { return nil }
        let utf16 = Array(value.utf16)
        let caret = min(sel.location, utf16.count)
        let tokenUnits = Array(token.utf16)
        let start = caret - tokenUnits.count
        guard start >= 0 else { return nil }
        guard Array(utf16[start..<caret]) == tokenUnits else { return nil }
        return (element, CFRange(location: start, length: tokenUnits.count), 0)
    }

    // Keystroke fallback: delete the token's characters, paste the emoji.
    private func replaceTokenBeforeCaretViaKeys(token: String, with emoji: String) {
        let count = token.count
        withPasteboard(emoji) {
            for _ in 0..<count { self.postKey(CGKeyCode(kVK_Delete)); usleep(9_000) }
            usleep(18_000)
            self.postPaste()
            usleep(28_000)
        }
    }

    private func replaceTokenInBuffer(token: String, with emoji: String) {
        if let r = buffer.range(of: token, options: .backwards) {
            buffer.replaceSubrange(r, with: emoji)
            saveActiveAppState()
        }
    }
}

// Per-word spelling-suspicion cache (#8). NSSpellChecker.checkSpelling is cheap but not free,
// and the gate is consulted on the hot completion path; cache the misspelled? verdict per word
// so a held key / repeated generation for the same word never re-queries the engine. Bounded
// LRU-ish (cleared wholesale past a cap — the working set of "current words" is tiny).
final class SpellSuspicionCache {
    static let shared = SpellSuspicionCache()
    private let lock = NSLock()
    private var cache: [String: Bool] = [:]

    func isMisspelled(_ word: String, tag: Int) -> Bool {
        // Same admissibility filter as correction(): short words, non-letters, and all-caps
        // acronyms are never "suspected" (too noisy to suppress completions on).
        guard word.count >= 3, word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return false }
        if word.allSatisfy({ $0.isUppercase }) { return false }
        let key = word.lowercased()
        lock.lock()
        if let v = cache[key] { lock.unlock(); return v }
        lock.unlock()
        let r = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0)
        let mis = r.location != NSNotFound && r.length > 0
        lock.lock()
        if cache.count > 512 { cache.removeAll() }
        cache[key] = mis
        lock.unlock()
        return mis
    }

    func clear() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }
}
