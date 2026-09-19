import CoreGraphics
import Foundation

// What a physical key press MEANS — decided once, by keycode, before a single
// character is allowed anywhere near the typed buffer.
//
// Why this exists: the event tap used to filter a handful of keys by name (Tab,
// backtick, Esc, Backspace, Return, ⌘/⌃/⌥ chords) and hand EVERYTHING else with a
// non-empty `keyboardString` to the typing path. On this machine that meant the arrow
// keys arrived as U+001C–U+001F, Home/End/PgUp/PgDn as U+0001/0004/000B/000C,
// forward-delete as U+007F, every F-key as U+0010, Help as U+0005, keypad Enter as
// U+0003 and keypad Clear as U+001B — all of it appended to the buffer that IS the
// prompt whenever AX text is unavailable, then learned into the style memory, the
// lexicon and the training log, and treated as "the user typed, re-arm generation".
//
// The rule that fixes it: decide by KEYCODE FIRST. A keycode is layout-independent
// (Dvorak, AZERTY, a Czech layout — 123 is still Left Arrow), while the produced
// character is exactly the thing that lies. The produced string is consulted only at
// the very end, and only to confirm that a key we already believe is a text key
// really did produce text.
//
// Pure on purpose: CoreGraphics + Foundation only, no app state, no AX, no `TyperApp`.
// The classification, the learnable-span bookkeeping and the rejected-suggestion match
// below are the three pieces of the input path that are worth testing without a window
// server, so they live together here and are exercised by `scripts/input_tests.swift`.
enum KeyClass: Equatable {
    case text(String)   // a real character the user typed; the payload is what to buffer
    case navigation     // arrows, Home/End, PgUp/PgDn, Help — moves the caret, types nothing
    case edit           // forward-delete, ⌥⌫/⌘⌫, ⌫ over a selection — mutates text we can't model
    case backspace      // a plain ⌫ with no selection: exactly one character came off the end
    case submit         // Return / keypad Enter
    case dismiss        // Esc / keypad Clear
    case accept         // Tab / backtick (the consuming accept tap's keys)
    case command        // a ⌘ or ⌃ chord we do not model
    case ignore         // F-keys, dead keys, anything that produced no usable text
}

enum InputSanitizer {

    // MARK: - Virtual keycodes
    //
    // The standard macOS ANSI virtual keycodes, spelled out rather than pulled from
    // Carbon so this file (and the test harness) needs nothing but Foundation.

    static let tabKey: Int64 = 48
    static let backtickKey: Int64 = 50
    static let backspaceKey: Int64 = 51
    static let returnKey: Int64 = 36
    static let keypadEnterKey: Int64 = 76
    static let escapeKey: Int64 = 53
    static let keypadClearKey: Int64 = 71
    static let forwardDeleteKey: Int64 = 117

    // Left/right/down/up, Home/End, PageUp/PageDown, Help. Every one of these moves the
    // insertion point (or opens a panel) without producing text, and every one of them
    // used to land in the buffer as a control character.
    static let navigationKeys: Set<Int64> = [123, 124, 125, 126, 115, 119, 116, 121, 114]

    // F1–F20. They all report U+0010 as their "character".
    static let functionKeys: Set<Int64> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    // MARK: - Classification

    // Decide what this keyDown is. `chars` is the event's `keyboardString` (nil/empty for
    // dead keys and modifier-only presses), `selectionNonEmpty` is whether the focused
    // field currently has a selection (only consulted for ⌫), and `isRepeat` is the
    // event's auto-repeat flag.
    //
    // Classification is deliberately repeat-INDEPENDENT: a held "a" really does type, a
    // held ← really does navigate. What auto-repeat changes is what the caller does with
    // the result — see `textIsLearnable(isRepeat:)` — so the flag is part of the
    // signature to keep that decision at the same call site rather than somewhere the
    // caller can forget it.
    static func classify(keycode: Int64, flags: CGEventFlags, chars: String?,
                         isRepeat: Bool, selectionNonEmpty: Bool) -> KeyClass {
        let command = flags.contains(.maskCommand)
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)

        // 1. Caret movement, with or without modifiers. ⇧→ extends a selection, ⌥→ jumps a
        //    word, ⌘→ jumps to the line end — all of them move the caret and none of them
        //    types, so they are navigation in every combination.
        if navigationKeys.contains(keycode) { return .navigation }

        // 2. Edits we cannot model character-for-character. Forward-delete removes the
        //    character AFTER the caret (nothing comes off the end of our buffer);
        //    ⌥⌫ / ⌘⌫ / ⌃⌫ remove a word or a line; a ⌫ with a selection removes the
        //    selection. Only a plain ⌫ with no selection is the one-character case the
        //    buffer can track itself.
        if keycode == forwardDeleteKey { return .edit }
        if keycode == backspaceKey {
            return (command || control || option || selectionNonEmpty) ? .edit : .backspace
        }

        // 3. Submit / dismiss. Keypad Enter is a Return (it reported U+0003 before);
        //    keypad Clear is an Esc (it reported U+001B).
        if keycode == returnKey || keycode == keypadEnterKey { return .submit }
        if keycode == escapeKey || keycode == keypadClearKey { return .dismiss }

        // 4. F-keys: never text, never a caret move.
        if functionKeys.contains(keycode) { return .ignore }

        // 5. The accept keys. ⌘`/⌃` are window- and app-cycling chords, not an accept;
        //    everything else on these two keycodes keeps the behaviour the accept tap
        //    already implements (Tab always, backtick only while a suggestion shows — the
        //    caller applies that second condition, since it depends on app state).
        if keycode == tabKey || keycode == backtickKey {
            if command || control { return .command }
            return .accept
        }

        // 6. ⌘ and ⌃ chords. ⌥ is NOT a command modifier on macOS — it is how é, –, —, …
        //    and “ ” are typed — so an ⌥ (or ⌥⇧) press falls through to the text gate
        //    below and is buffered like any other character.
        if command || control { return .command }

        // 7. The text gate. A key we believe is a text key still has to prove it produced
        //    text: dead keys (⌥e) and modifier-only presses report nothing at all, and are
        //    the one case where nothing happened and nothing needs doing.
        guard let chars, !chars.isEmpty else { return .ignore }
        // 8. It produced SOMETHING, but not something we are willing to buffer: a
        //    private-use glyph (⌥⇧K is U+F8FF, the Apple logo; a Nerd Font key types a PUA
        //    icon), a soft hyphen, a stray control. The character still lands in the
        //    field — so treating this as `.ignore` left the buffer one character behind the
        //    document with nothing to tell us, a silent desync that persists until the next
        //    resync happens to fire. It is an edit we cannot model: re-sync instead.
        guard TextSanitizer.isClean(chars) else { return .edit }
        return .text(chars)
    }

    // Auto-repeat text is still typed (it reaches the field, so it must reach the buffer),
    // but it must never teach the vocabulary: a leaned-on key produces "wwwww", which is
    // an artifact, not a word.
    static func textIsLearnable(isRepeat: Bool) -> Bool { !isRepeat }

    // MARK: - Harmless chords

    // ⌘ chords that neither move the caret nor mutate the field's text, so there is
    // nothing to re-sync afterwards. Deliberately short and explicit — anything not on
    // this list pays one debounced AX re-sync, which is cheap and always safe. Requires
    // ⌘ alone: ⌘⌥/⌘⌃/⌘⇧ variants mean something different in enough apps that they are
    // not worth assuming about.
    static let harmlessChordKeys: Set<Int64> = [
        8,   // ⌘C  copy
        1,   // ⌘S  save
        48,  // ⌘⇥  application switcher
        49,  // ⌘space  Spotlight
        12,  // ⌘Q  quit
        13,  // ⌘W  close window
        46,  // ⌘M  minimise
        4,   // ⌘H  hide
        43,  // ⌘,  preferences
        35,  // ⌘P  print
        24,  // ⌘=  zoom in
        27,  // ⌘-  zoom out
        29,  // ⌘0  actual size
        // Inert formatting toggles. They restyle the selection (or arm a style for what is
        // typed next) without moving the insertion point or changing a single character of
        // text, so the buffer still describes the field exactly. Only the bare ⌘ form: the
        // ⇧ variants are different commands in enough apps (⌘⇧B is Favourites/Build, ⌘⇧U is
        // Uppercase) that they keep paying the re-sync, and `isHarmlessChord` already
        // refuses any chord carrying ⇧/⌥/⌃.
        //
        // Not here on purpose: ⌘K (inserts a link, clears a terminal) and ⌘R/⌘N/⌘T/⌘O/⌘L/⌘F
        // (open UI, move focus, or start a Find that jumps the caret). A focus change is
        // harmless to re-sync — the debounced read simply re-reads the new field — so when
        // in doubt the chord stays off the list.
        11,  // ⌘B  bold
        34,  // ⌘I  italic
        32,  // ⌘U  underline
    ]

    static func isHarmlessChord(keycode: Int64, flags: CGEventFlags) -> Bool {
        guard flags.contains(.maskCommand) else { return false }
        guard !flags.contains(.maskControl), !flags.contains(.maskAlternate),
              !flags.contains(.maskShift) else { return false }
        return harmlessChordKeys.contains(keycode)
    }

    // MARK: - Rejected-suggestion memory

    // The suggestion the user just turned down, together with the tail of the context it
    // was generated for. Greedy decoding is deterministic, so regenerating from the same
    // context produces the same text — without this the rejected suggestion pops straight
    // back up and the only way out is to keep typing.
    //
    // Scope, honestly stated: this only ever bites while the context tail is UNCHANGED.
    // That covers the two cases it is for — Esc (the context does not move at all) and
    // typing past a suggestion and then backspacing back to where it was shown. It does
    // NOT, and cannot, suppress anything once the user has typed on past: the context tail
    // has changed by then, so a fresh generation is a genuinely different suggestion for a
    // genuinely different place in the sentence, and suppressing it would be wrong.
    struct RejectedSuggestion: Equatable {
        var contextTail: String
        var text: String
    }

    // The slice of context a re-show is judged against. Short enough that it is genuinely
    // "the same place in the same sentence", long enough that two different sentences
    // rarely collide.
    static func contextTail(_ context: String, max: Int = 48) -> String {
        String(context.suffix(max))
    }

    // True when `suggestion` is the text the user already rejected at the same point in the
    // same context — the one case where showing it again is certain to be wrong. A
    // different context tail is a material change and clears the block implicitly.
    //
    // The match is prefix-tolerant in BOTH directions, because what is recorded as rejected
    // is whatever was on screen at the moment of the Esc, and the streaming painter shows a
    // suggestion while it is still arriving: Esc during the stream records the partial
    // ("ld to") while the generation that lands a moment later is the whole thing
    // ("ld today"). An exact-equality test let that final text straight back onto the
    // screen, which is precisely the suggestion the user just dismissed, one word longer.
    static func isRepeatOfRejected(_ rejected: RejectedSuggestion?,
                                   contextTail: String, suggestion: String) -> Bool {
        guard let rejected, !rejected.text.isEmpty, !suggestion.isEmpty else { return false }
        guard rejected.contextTail == contextTail else { return false }
        return suggestion.hasPrefix(rejected.text) || rejected.text.hasPrefix(suggestion)
    }
}

// MARK: - Learnable-span bookkeeping

// A stretch of the typed buffer that the user did not write. Three sources, and they are
// kept apart because they are not equally poisonous:
//
//  • `.model` — text typer itself inserted on a Tab/backtick accept. Learning it back
//    would be a closed loop: the lexicon gains the model's own words, those words then
//    get a logit boost, and the model emits them more often. It must be excluded from
//    BOTH the lexicon and the style memory (the style memory's job is the user's voice).
//  • `.autoRepeat` — characters produced by a key held down. They are real keystrokes
//    and belong in a style sample ("noooo way" is how someone writes), but "nooooo" is
//    not a vocabulary entry, so they are excluded from the lexicon only.
//  • `.resync` — text read back out of the host app's own AXValue when the caret moved
//    and the buffer had to be rebuilt. NOBODY typed it in this session: it is up to 500
//    characters of whatever happened to be in the field — a received email, a document
//    someone else wrote, a page of someone else's prose. Recording it as "the user's
//    voice" is how style.txt filled with writing the user never produced, so it is
//    excluded from BOTH stores, exactly like `.model`.
struct UnlearnableSpan: Equatable {
    enum Source: Hashable { case model, autoRepeat, resync }

    // Sources that are not the user's own writing, and must therefore be cut out of the
    // style memory as well as the lexicon. (`.autoRepeat` is missing on purpose: a held
    // key is still this person typing, it is just not a vocabulary entry.)
    static let notTheUsersVoice: Set<Source> = [.model, .resync]

    var start: Int          // character offset into the buffer
    var text: String        // exactly what was inserted, for verification
    var source: Source

    var length: Int { text.count }
    var end: Int { start + length }
}

enum LearnableSpans {

    // Re-base spans after the buffer was front-truncated by `removed` characters. A span
    // that was partly cut keeps only its surviving tail; one cut away entirely is dropped.
    static func shifted(_ spans: [UnlearnableSpan], byRemoving removed: Int) -> [UnlearnableSpan] {
        guard removed > 0 else { return spans }
        var out: [UnlearnableSpan] = []
        for span in spans {
            let newStart = span.start - removed
            if newStart >= 0 { out.append(UnlearnableSpan(start: newStart, text: span.text, source: span.source)); continue }
            let keep = span.length + newStart      // newStart is negative: how much survived
            guard keep > 0 else { continue }
            out.append(UnlearnableSpan(start: 0, text: String(span.text.suffix(keep)), source: span.source))
        }
        return out
    }

    // Confirm every span still sits exactly where it claims in `chars`. Returns nil if any
    // one of them does not, which is the signal that the buffer was rewritten by a path
    // that does not keep this bookkeeping (a typo correction replacing a word, a hand
    // reset). Callers must treat nil as "cannot attribute this text" and learn nothing,
    // rather than guess and risk teaching the model its own output back.
    static func verified(_ spans: [UnlearnableSpan], in chars: [Character]) -> [UnlearnableSpan]? {
        var out: [UnlearnableSpan] = []
        for span in spans {
            guard span.start >= 0, span.end <= chars.count else { return nil }
            guard Array(span.text) == Array(chars[span.start..<span.end]) else { return nil }
            out.append(span)
        }
        return out
    }

    // The maximal runs of `chars` at or after `lowerBound` that no span covers, in order.
    // Runs are returned separately (never concatenated) so a caller cannot accidentally
    // glue "hel" and "lo" into "hello" across a removed span.
    static func runs(in chars: [Character], excluding spans: [UnlearnableSpan], from lowerBound: Int = 0) -> [String] {
        let start = max(0, min(lowerBound, chars.count))
        let ordered = spans.sorted { $0.start < $1.start }
        var out: [String] = []
        var cursor = start
        for span in ordered {
            let spanStart = max(span.start, start)
            let spanEnd = min(max(span.end, start), chars.count)
            guard spanEnd > cursor else { continue }
            if spanStart > cursor { out.append(String(chars[cursor..<spanStart])) }
            cursor = spanEnd
        }
        if cursor < chars.count { out.append(String(chars[cursor..<chars.count])) }
        return out.filter { !$0.isEmpty }
    }
}
