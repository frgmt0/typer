import Foundation

// The single whitelist that decides whether a piece of text is fit to be learned from,
// persisted, or folded back into a prompt.
//
// Why this exists: every non-text key (arrows, Home/End, PgUp/PgDn, forward-delete,
// F-keys, keypad Enter, Clear) arrives from the event tap carrying a *control* character
// in its unicode payload — U+001C–U+001F for the arrows, U+0001/0004/000B/000C for
// navigation, U+007F for forward-delete, U+0010 for the F-keys. Appending those to the
// typed buffer silently poisoned every learning store: style.txt lines with an embedded
// U+001C, training.jsonl contexts full of escape codes, lexicon entries like "wwwww"
// from a held key. This type is the shared gate that keeps all of it out.
//
// The policy is deliberately a *whitelist by exclusion*: everything is allowed except
// classes of scalar that can never be part of real typed prose —
//   • C0/C1 controls, except tab / newline / carriage return
//   • private-use areas (nothing portable, often app-specific glyph hacks)
//   • format characters (Cf: bidi overrides, soft hyphen, invisible separators), except
//     U+200D ZERO WIDTH JOINER, which real emoji sequences need
//   • U+FFFD REPLACEMENT CHARACTER — the fingerprint of a decoding failure
//   • noncharacters (U+FDD0–U+FDEF and the two at the top of every plane)
// Everything else — accents, CJK, em dashes, emoji, U+FE0F variation selectors — passes.
//
// Pure and Foundation-only on purpose: it is used by the app, by the store migration,
// and by the standalone test harness, and must not drag in any app state.
enum TextSanitizer {

    // MARK: - Scalar policy

    // True if `s` may appear in text we learn from, store, or send to the model.
    static func isAllowed(_ s: Unicode.Scalar) -> Bool {
        let v = s.value

        // Fast path: plain printable ASCII, by far the common case.
        if v >= 0x20, v < 0x7F { return true }

        // The three whitespace controls that are genuine text.
        if v == 0x09 || v == 0x0A || v == 0x0D { return true }

        // C0 and C1 controls (this is where every stray arrow/Home/F-key landed).
        if v <= 0x1F { return false }
        if v >= 0x7F, v <= 0x9F { return false }

        // Private use: BMP + the two supplementary planes.
        if v >= 0xE000, v <= 0xF8FF { return false }
        if v >= 0xF0000, v <= 0xFFFFD { return false }
        if v >= 0x100000, v <= 0x10FFFD { return false }

        // Decoding-failure marker.
        if v == 0xFFFD { return false }

        // Noncharacters: the Arabic Presentation Forms block and U+xFFFE/U+xFFFF in
        // every plane.
        if v >= 0xFDD0, v <= 0xFDEF { return false }
        if (v & 0xFFFE) == 0xFFFE { return false }

        // Format characters (Cf) — invisible and never typed on purpose — except the
        // zero-width joiner and the tag block, both of which hold real emoji together.
        if !isEmojiFormatException(s), s.properties.generalCategory == .format { return false }

        return true
    }

    // The two Cf exceptions, shared by the allow policy and the invisible-strip policy so
    // they can never drift apart:
    //   • U+200D ZERO WIDTH JOINER — multi-person and profession emoji are built from it.
    //   • U+E0020–U+E007F, the TAG block — a subdivision flag (🏴󠁧󠁢󠁥󠁮󠁧󠁿, 🏴󠁧󠁢󠁳󠁣󠁴󠁿, 🏴󠁧󠁢󠁷󠁬󠁳󠁿) is U+1F3F4
    //     followed by tag letters and terminated by U+E007F. Treating those as disallowed
    //     mangled the flag in the buffer and dropped any completion containing one, while
    //     the C++ helper (`is_format_scalar`) allowed the same block — the two sides of the
    //     same whitelist disagreed. U+E0001, the deprecated language tag, is deliberately
    //     NOT in the range: it holds nothing together and is still stripped.
    @inline(__always)
    static func isEmojiFormatException(_ s: Unicode.Scalar) -> Bool {
        s.value == 0x200D || (s.value >= 0xE0020 && s.value <= 0xE007F)
    }

    // True if every scalar in `s` is allowed. An empty string is clean.
    static func isClean(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy(isAllowed)
    }

    // MARK: - Held-key runs

    // True if `word` contains four or more identical consecutive characters — the
    // signature of a key held down (auto-repeat) rather than a word someone meant to
    // type. Three is the English ceiling for real words, so the bar sits at four:
    // "wwwww" and "aaaa" are artifacts, "balloon" and "committee" are not.
    static func hasHeldKeyRun(_ word: String) -> Bool {
        var previous: Character?
        var run = 0
        for ch in word {
            if ch == previous {
                run += 1
                if run >= 4 { return true }
            } else {
                previous = ch
                run = 1
            }
        }
        return false
    }

    // MARK: - Invisible formatting

    // True for scalars that are invisible *formatting* rather than text: the whole Cf
    // general category (bidi marks and overrides, the soft hyphen, zero-width space and
    // non-joiner, the invisible separators) plus U+FEFF, which is Cf too but is worth
    // naming because it is the one that actually shows up — a byte-order mark carried in
    // by an app's AX text.
    //
    // U+200D ZERO WIDTH JOINER and the U+E0020–U+E007F tag block are excluded: they are
    // invisible, but they are what hold a family/profession emoji and a subdivision flag
    // together, and removing them would silently rewrite real text (see
    // `isEmojiFormatException`).
    static func isInvisibleFormat(_ s: Unicode.Scalar) -> Bool {
        if isEmojiFormatException(s) { return false }
        return s.properties.generalCategory == .format
    }

    // `s` with every invisible format scalar removed.
    //
    // This is a POLICY choice, not a convenience. These characters come from applications
    // (an AX value that starts with a BOM, a bidi mark around an RTL name), never from
    // the keyboard, and they sit inside otherwise perfectly good text. Measured on a real
    // capture directory, 897 of 14,503 training rows and 17 style lines contained NOTHING
    // disallowed except invisibles — dropping them would have thrown away 6% of the corpus
    // to delete characters nobody can see. So invisibles are stripped first and the
    // drop-the-whole-row rule then applies only to what is left (controls, private use,
    // U+FFFD), which really does indicate the text is broken.
    static func strippingInvisibles(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: isInvisibleFormat) else { return s }
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where !isInvisibleFormat(scalar) { out.append(scalar) }
        return String(out)
    }

    // MARK: - Last resort

    // `s` with every disallowed scalar removed. This is the last-resort path for text
    // that is about to be handed to the model and cannot simply be dropped — NEVER the
    // path for anything we persist. A stored sentence with characters silently removed
    // is worse than no sentence at all, so the write paths reject instead of stripping.
    static func stripped(_ s: String) -> String {
        if isClean(s) { return s }
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where isAllowed(scalar) { out.append(scalar) }
        return String(out)
    }
}
