import CoreGraphics
import Foundation

// Standalone assert harness for the input layer: InputSanitizer's keycode classification
// (the gate that decides whether a key press is text at all), the harmless-chord list, the
// rejected-suggestion match, and the learnable-span bookkeeping that keeps typer's own
// accepted text out of the lexicon and the style memory.
//
// Deliberately NOT in scripts/typer/: that directory is compiled into the app by glob
// (see scripts/build.sh), and a second entry point would break the build.
//
// Run it through scripts/run_input_tests.sh, which compiles and invokes it.
@main
struct InputTests {

    static var checks = 0
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ what: String) {
        checks += 1
        if !condition() {
            failures += 1
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
        }
    }

    static func section(_ name: String) { print("== \(name)") }

    // Convenience: classify with the defaults most cases want.
    static func classify(_ keycode: Int64, _ flags: CGEventFlags = [], chars: String? = nil,
                         isRepeat: Bool = false, selection: Bool = false) -> KeyClass {
        InputSanitizer.classify(keycode: keycode, flags: flags, chars: chars,
                                isRepeat: isRepeat, selectionNonEmpty: selection)
    }

    // Modifier sets, named the way the keyboard is.
    static let none: CGEventFlags = []
    static let cmd: CGEventFlags = .maskCommand
    static let ctrl: CGEventFlags = .maskControl
    static let opt: CGEventFlags = .maskAlternate
    static let shift: CGEventFlags = .maskShift

    static func main() {

        // MARK: - Navigation keys
        //
        // The whole reason this layer exists: every one of these reported a CONTROL
        // CHARACTER as its "typed text" and was appended to the buffer that becomes the
        // prompt. They must classify as navigation regardless of the payload, regardless
        // of modifiers, and regardless of auto-repeat.

        section("navigation keys")

        let navigation: [(Int64, String, String)] = [
            (123, "left arrow", "\u{001C}"),
            (124, "right arrow", "\u{001D}"),
            (126, "up arrow", "\u{001E}"),
            (125, "down arrow", "\u{001F}"),
            (115, "Home", "\u{0001}"),
            (119, "End", "\u{0004}"),
            (116, "PageUp", "\u{000B}"),
            (121, "PageDown", "\u{000C}"),
            (114, "Help", "\u{0005}"),
        ]
        for (code, name, payload) in navigation {
            check(classify(code, chars: payload) == .navigation, "\(name) (\(code)) is navigation")
            check(classify(code, shift, chars: payload) == .navigation, "⇧\(name) is navigation (selection extend)")
            check(classify(code, opt, chars: payload) == .navigation, "⌥\(name) is navigation (word jump)")
            check(classify(code, cmd, chars: payload) == .navigation, "⌘\(name) is navigation (line/document jump)")
            check(classify(code, [.maskCommand, .maskShift], chars: payload) == .navigation,
                  "⌘⇧\(name) is navigation")
            check(classify(code, chars: payload, isRepeat: true) == .navigation,
                  "a held \(name) is still navigation")
        }

        // MARK: - Edits the buffer cannot mirror

        section("edit keys")

        check(classify(117, chars: "\u{007F}") == .edit, "forward delete (117) is an edit, not U+007F text")
        check(classify(117, cmd, chars: "\u{007F}") == .edit, "⌘forward-delete is an edit")

        check(classify(51, chars: "\u{0008}") == .backspace, "a plain ⌫ with no selection is the one-char case")
        check(classify(51, chars: "\u{0008}", isRepeat: true) == .backspace, "a held ⌫ is still the one-char case")
        check(classify(51, opt, chars: "\u{0008}") == .edit, "⌥⌫ deletes a word — not one character")
        check(classify(51, cmd, chars: "\u{0008}") == .edit, "⌘⌫ deletes to the line start")
        check(classify(51, ctrl, chars: "\u{0008}") == .edit, "⌃⌫ is an edit")
        check(classify(51, chars: "\u{0008}", selection: true) == .edit, "⌫ over a selection is an edit")
        check(classify(51, shift, chars: "\u{0008}") == .backspace, "⇧⌫ is still one character")

        // MARK: - Submit / dismiss

        section("submit and dismiss")

        check(classify(36, chars: "\r") == .submit, "Return (36) is submit")
        check(classify(76, chars: "\u{0003}") == .submit, "keypad Enter (76) is submit, not U+0003 text")
        check(classify(36, shift, chars: "\r") == .submit, "⇧Return is submit (the caller inserts the newline)")
        check(classify(53, chars: "\u{001B}") == .dismiss, "Esc (53) is dismiss")
        check(classify(71, chars: "\u{001B}") == .dismiss, "keypad Clear (71) is dismiss, not U+001B text")

        // MARK: - F-keys

        section("function keys")

        let fKeys: [Int64] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for code in fKeys {
            check(classify(code, chars: "\u{0010}") == .ignore, "F-key \(code) is ignored, not U+0010 text")
        }
        check(classify(96, chars: "\u{0010}") == .ignore, "F5 (96) is ignored")
        check(classify(122, cmd, chars: "\u{0010}") == .ignore, "⌘F1 is still ignored")

        // MARK: - Accept keys

        section("accept keys")

        check(classify(48, chars: "\t") == .accept, "Tab (48) is an accept key")
        check(classify(50, chars: "`") == .accept, "backtick (50) is an accept key")
        check(classify(48, cmd, chars: "\t") == .command, "⌘⇥ is an app-switcher chord, not an accept")
        check(classify(50, cmd, chars: "`") == .command, "⌘` is a window-cycling chord, not an accept")
        check(classify(50, ctrl, chars: "`") == .command, "⌃` is a chord, not an accept")
        check(classify(48, opt, chars: "\t") == .accept, "⌥⇥ still reaches the accept tap (unchanged behaviour)")

        // MARK: - Command chords

        section("command chords")

        check(classify(0, cmd, chars: "a") == .command, "⌘A is a command chord")
        check(classify(0, ctrl, chars: "\u{0001}") == .command, "⌃A is a command chord (and never U+0001 text)")
        check(classify(14, ctrl, chars: "\u{0005}") == .command, "⌃E is a command chord")
        check(classify(40, ctrl, chars: "\u{000B}") == .command, "⌃K is a command chord")
        check(classify(6, [.maskCommand, .maskShift], chars: "z") == .command, "⌘⇧Z is a command chord")
        check(classify(9, cmd, chars: "v") == .command, "⌘V is a command chord")
        check(classify(16, cmd, chars: "y") == .command, "⌘Y is a command chord")

        // MARK: - Text, and the option key

        section("text keys")

        check(classify(0, chars: "a") == .text("a"), "a plain letter is text")
        check(classify(0, chars: "a", isRepeat: true) == .text("a"),
              "a HELD letter is still text — it really does type")
        check(classify(0, shift, chars: "A") == .text("A"), "⇧ + letter is text")

        // ⌥ is a TEXT modifier on macOS, not a command modifier. Treating it as a command
        // meant every é, –, —, … and “ ” reached the field but never the buffer, so the
        // prompt silently disagreed with the document.
        check(classify(14, opt, chars: "é") == .text("é"), "⌥e-then-e composes é — text, not a chord")
        check(classify(27, opt, chars: "–") == .text("–"), "⌥- is an en dash — text")
        check(classify(27, [.maskAlternate, .maskShift], chars: "—") == .text("—"), "⌥⇧- is an em dash — text")
        check(classify(43, opt, chars: "≤") == .text("≤"), "⌥, is ≤ — text")
        check(classify(41, opt, chars: "…") == .text("…"), "⌥; is an ellipsis — text")
        check(classify(33, opt, chars: "“") == .text("“"), "⌥[ is a curly quote — text")
        check(classify(14, [.maskAlternate, .maskCommand], chars: "é") == .command,
              "⌥⌘e IS a chord — ⌘ decides")

        // A dead key produces no character at all until the next press composes it.
        check(classify(14, opt, chars: nil) == .ignore, "⌥e as a dead key (no chars) is ignored")
        check(classify(14, opt, chars: "") == .ignore, "⌥e as a dead key (empty chars) is ignored")

        // The final gate: whatever the keycode claims, a control / private-use / U+FFFD
        // payload is not text.
        //
        // It is not `.ignore` either. The key really did put a character in the field — a
        // Nerd Font PUA glyph, ⌥⇧K's U+F8FF, a soft hyphen — and refusing to buffer it
        // without saying so left the buffer one character behind the document with nothing
        // to signal it. `.edit` is "the field changed in a way we cannot mirror": re-sync.
        section("the text gate refuses non-text payloads as an unmodellable edit")

        for payload in ["\u{001C}", "\u{0010}", "\u{007F}", "\u{0001}", "a\u{001C}b",
                        "\u{FFFD}", "\u{E000}", "\u{F8FF}", "\u{00AD}", "\u{FEFF}"] {
            let escaped = payload.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            check(classify(0, chars: payload) == .edit, "payload \(escaped) is an edit, never text")
        }
        // Keycode rules still win: an F-key and an arrow key are NOT edits just because
        // their payload is a control character.
        check(classify(96, chars: "\u{0010}") == .ignore, "an F-key's U+0010 is still ignored, not an edit")
        check(classify(123, chars: "\u{001C}") == .navigation, "an arrow's U+001C is still navigation")
        check(classify(117, chars: "\u{007F}") == .edit, "forward delete is an edit by keycode, not by payload")
        check(classify(0, cmd, chars: "\u{0001}") == .command, "a ⌘ chord is a chord whatever it produced")
        // A tag-block scalar is allowed text now (the flag-sequence exemption), so a key
        // that produced one is buffered rather than re-synced.
        check(classify(0, chars: "\u{E0041}") == .text("\u{E0041}"), "a tag-block scalar is text")
        check(classify(0, chars: "café") == .text("café"), "accented text passes the gate")
        check(classify(0, chars: "👨‍👩‍👧") == .text("👨‍👩‍👧"), "a ZWJ emoji sequence passes the gate")
        check(classify(0, chars: "\n") == .text("\n"), "a newline payload passes the gate")

        // MARK: - Auto-repeat learnability

        section("auto-repeat learnability")

        check(InputSanitizer.textIsLearnable(isRepeat: false), "a real keystroke teaches the lexicon")
        check(!InputSanitizer.textIsLearnable(isRepeat: true),
              "an auto-repeat keystroke does not — this is where \"wwwww\" came from")

        // MARK: - Harmless chords

        section("harmless chords")

        for (code, name) in [(Int64(8), "⌘C"), (1, "⌘S"), (48, "⌘⇥"), (49, "⌘space"),
                             (12, "⌘Q"), (13, "⌘W"), (46, "⌘M"), (4, "⌘H"),
                             (43, "⌘,"), (35, "⌘P"), (24, "⌘="), (27, "⌘-"), (29, "⌘0"),
                             // Formatting toggles: they restyle, they do not move the caret
                             // or change a character of text.
                             (11, "⌘B"), (34, "⌘I"), (32, "⌘U")] {
            check(InputSanitizer.isHarmlessChord(keycode: code, flags: cmd), "\(name) needs no re-sync")
        }
        for (code, name) in [(Int64(9), "⌘V"), (7, "⌘X"), (6, "⌘Z"), (0, "⌘A"), (3, "⌘F"), (5, "⌘G"),
                             // Deliberately NOT on the list: ⌘K inserts a link (or clears a
                             // terminal), and ⌘R/⌘N/⌘T/⌘O/⌘L open UI or move focus.
                             (40, "⌘K"), (15, "⌘R"), (45, "⌘N"), (17, "⌘T"), (31, "⌘O"), (37, "⌘L")] {
            check(!InputSanitizer.isHarmlessChord(keycode: code, flags: cmd), "\(name) must re-sync")
        }
        // The ⇧ variants are different commands in enough apps (⌘⇧B, ⌘⇧U) that they keep
        // paying the re-sync.
        for (code, name) in [(Int64(11), "⌘⇧B"), (34, "⌘⇧I"), (32, "⌘⇧U")] {
            check(!InputSanitizer.isHarmlessChord(keycode: code, flags: [.maskCommand, .maskShift]),
                  "\(name) is not the same command as its bare form")
        }
        check(!InputSanitizer.isHarmlessChord(keycode: 8, flags: [.maskCommand, .maskShift]),
              "⌘⇧C is not the same command as ⌘C")
        check(!InputSanitizer.isHarmlessChord(keycode: 8, flags: [.maskCommand, .maskAlternate]),
              "⌘⌥C is not the same command as ⌘C")
        check(!InputSanitizer.isHarmlessChord(keycode: 8, flags: ctrl), "⌃C is not a ⌘ chord")
        check(!InputSanitizer.isHarmlessChord(keycode: 8, flags: none), "a bare C is not a chord at all")

        // MARK: - Rejected-suggestion memory

        section("rejected-suggestion match")

        check(InputSanitizer.contextTail("short") == "short", "a short context is its own tail")
        check(InputSanitizer.contextTail(String(repeating: "x", count: 100)).count == 48,
              "a long context is cut to the tail window")
        check(InputSanitizer.contextTail("abcdef", max: 3) == "def", "the tail is taken from the END")

        let rejected = InputSanitizer.RejectedSuggestion(contextTail: "I'll send it over ", text: "tomorrow morning")
        check(InputSanitizer.isRepeatOfRejected(rejected, contextTail: "I'll send it over ",
                                                suggestion: "tomorrow morning"),
              "the identical suggestion for the identical context is refused")
        check(!InputSanitizer.isRepeatOfRejected(rejected, contextTail: "I'll send it over ",
                                                 suggestion: "this afternoon"),
              "a different suggestion for the same context is allowed")
        check(!InputSanitizer.isRepeatOfRejected(rejected, contextTail: "let me check and ",
                                                 suggestion: "tomorrow morning"),
              "the same suggestion after the context moved on is allowed")
        check(!InputSanitizer.isRepeatOfRejected(nil, contextTail: "anything", suggestion: "anything"),
              "nothing is refused when nothing was rejected")
        check(!InputSanitizer.isRepeatOfRejected(
                InputSanitizer.RejectedSuggestion(contextTail: "ctx", text: ""),
                contextTail: "ctx", suggestion: ""),
              "an empty rejection never blocks anything")
        check(!InputSanitizer.isRepeatOfRejected(rejected, contextTail: "I'll send it over ", suggestion: ""),
              "an empty candidate is not a repeat of anything")

        // Esc during the STREAM records the partial that was on screen, while the
        // generation that lands a moment later is the whole thing. Exact equality let the
        // dismissed suggestion straight back up, one word longer, so the match is
        // prefix-tolerant in both directions.
        let partial = InputSanitizer.RejectedSuggestion(contextTail: "see you ", text: "tomorrow mor")
        check(InputSanitizer.isRepeatOfRejected(partial, contextTail: "see you ",
                                                suggestion: "tomorrow morning"),
              "the completed form of a dismissed partial is still the dismissed suggestion")
        let whole = InputSanitizer.RejectedSuggestion(contextTail: "see you ", text: "tomorrow morning")
        check(InputSanitizer.isRepeatOfRejected(whole, contextTail: "see you ", suggestion: "tomorrow mor"),
              "and a shorter re-decode of a dismissed suggestion is refused too")
        check(!InputSanitizer.isRepeatOfRejected(whole, contextTail: "see you ", suggestion: "later today"),
              "a genuinely different continuation is still allowed")
        check(!InputSanitizer.isRepeatOfRejected(whole, contextTail: "see you at ",
                                                 suggestion: "tomorrow morning"),
              "and the tail still has to match — a moved context clears the block")

        // MARK: - Learnable spans

        section("LearnableSpans.runs")

        // "hello world" with " world" (chars 5..<11) inserted by the model.
        let buffer = Array("hello world")
        let modelSpan = UnlearnableSpan(start: 5, text: " world", source: .model)
        check(LearnableSpans.runs(in: buffer, excluding: [modelSpan]) == ["hello"],
              "the model's insertion is cut out of the learnable text")
        check(LearnableSpans.runs(in: buffer, excluding: []) == ["hello world"],
              "no spans means the whole buffer is learnable")
        check(LearnableSpans.runs(in: [], excluding: []).isEmpty, "an empty buffer yields no runs")

        // A span in the MIDDLE must leave two separate runs — never one concatenation, or
        // "hel" + "lo" would become a word nobody typed.
        let split = Array("helXXlo")
        check(LearnableSpans.runs(in: split, excluding: [UnlearnableSpan(start: 3, text: "XX", source: .model)])
              == ["hel", "lo"],
              "a span in the middle leaves two runs, not one glued word")

        // A span at the very start, and one running to the very end.
        check(LearnableSpans.runs(in: buffer, excluding: [UnlearnableSpan(start: 0, text: "hello", source: .model)])
              == [" world"], "a span at the start leaves the tail")
        check(LearnableSpans.runs(in: buffer, excluding: [UnlearnableSpan(start: 0, text: "hello world", source: .model)])
              .isEmpty, "a span covering everything leaves nothing")

        // Two spans, given out of order.
        let two = [UnlearnableSpan(start: 7, text: "or", source: .model),
                   UnlearnableSpan(start: 0, text: "he", source: .autoRepeat)]
        check(LearnableSpans.runs(in: buffer, excluding: two) == ["llo w", "ld"],
              "spans are applied in position order however they were recorded")

        // `from:` is the lexicon watermark — only text past it is a candidate.
        check(LearnableSpans.runs(in: buffer, excluding: [modelSpan], from: 2) == ["llo"],
              "the watermark trims the front of the first run")
        check(LearnableSpans.runs(in: buffer, excluding: [modelSpan], from: 5).isEmpty,
              "a watermark inside a span leaves nothing learnable")
        check(LearnableSpans.runs(in: buffer, excluding: [], from: 99).isEmpty,
              "a watermark past the end is clamped, not a crash")

        section("LearnableSpans.verified")

        check(LearnableSpans.verified([modelSpan], in: buffer) == [modelSpan],
              "a span that still matches the buffer verifies")
        check(LearnableSpans.verified([], in: buffer) == [], "no spans always verifies")
        check(LearnableSpans.verified([UnlearnableSpan(start: 5, text: " WORLD", source: .model)], in: buffer) == nil,
              "a span whose text no longer matches fails, so nothing is learned")
        check(LearnableSpans.verified([UnlearnableSpan(start: 8, text: " world", source: .model)], in: buffer) == nil,
              "a span running past the end of the buffer fails")
        check(LearnableSpans.verified([UnlearnableSpan(start: -1, text: "h", source: .model)], in: buffer) == nil,
              "a negative start fails")
        check(LearnableSpans.verified([modelSpan], in: Array("hello")) == nil,
              "a span the buffer outgrew (truncated behind us) fails")

        section("LearnableSpans.shifted")

        let spans = [UnlearnableSpan(start: 10, text: "abcd", source: .model)]
        check(LearnableSpans.shifted(spans, byRemoving: 0) == spans, "removing nothing changes nothing")
        check(LearnableSpans.shifted(spans, byRemoving: 4)
              == [UnlearnableSpan(start: 6, text: "abcd", source: .model)],
              "front-truncation moves a whole span back by the same amount")
        check(LearnableSpans.shifted(spans, byRemoving: 12)
              == [UnlearnableSpan(start: 0, text: "cd", source: .model)],
              "a partly-cut span keeps only its surviving tail")
        check(LearnableSpans.shifted(spans, byRemoving: 14).isEmpty,
              "a span cut away entirely is dropped")
        check(LearnableSpans.shifted(spans, byRemoving: 10)
              == [UnlearnableSpan(start: 0, text: "abcd", source: .model)],
              "a cut landing exactly on the span start keeps all of it")

        // The bookkeeping has to survive a shift: shift, then the runs must still line up.
        let long = Array("0123456789abcd")
        let shifted = LearnableSpans.shifted(spans, byRemoving: 4)
        let truncated = Array(long.dropFirst(4))
        check(LearnableSpans.verified(shifted, in: truncated) != nil,
              "a shifted span still verifies against the truncated buffer")
        check(LearnableSpans.runs(in: truncated, excluding: shifted) == ["456789"],
              "and still excludes exactly the right characters")

        section("span sources are kept apart")

        // Style memory excludes only the model's text; a held key is still the user's own
        // writing, it is just not vocabulary.
        let mixed = [UnlearnableSpan(start: 0, text: "he", source: .autoRepeat),
                     UnlearnableSpan(start: 5, text: " world", source: .model)]
        check(LearnableSpans.runs(in: buffer, excluding: mixed.filter { $0.source == .model }) == ["hello"],
              "style memory keeps auto-repeat text and drops only the model's")
        check(LearnableSpans.runs(in: buffer, excluding: mixed) == ["llo"],
              "the lexicon drops both")

        // Resynced text is the third source, and it is the one the STYLE memory most needed:
        // a caret re-sync fills the buffer with up to 500 characters of whatever the host
        // app had in the field — someone else's email, someone else's document — and that
        // was being recorded as "the user's voice".
        let resynced = [UnlearnableSpan(start: 0, text: "hello", source: .resync)]
        check(UnlearnableSpan.notTheUsersVoice.contains(.resync), "resynced host text is not the user's voice")
        check(UnlearnableSpan.notTheUsersVoice.contains(.model), "nor is typer's own output")
        check(!UnlearnableSpan.notTheUsersVoice.contains(.autoRepeat),
              "but a held key IS this person typing — it is just not vocabulary")
        check(LearnableSpans.runs(in: buffer,
                                  excluding: resynced.filter { UnlearnableSpan.notTheUsersVoice.contains($0.source) })
              == [" world"],
              "style memory drops resynced host text and keeps what was typed after it")
        check(LearnableSpans.runs(in: buffer, excluding: resynced) == [" world"],
              "the lexicon drops it too (it excludes every span)")
        check(LearnableSpans.verified(resynced, in: buffer) == resynced,
              "a whole-buffer resync span verifies like any other")

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) FAILURES\n".utf8))
            exit(1)
        }
    }
}
