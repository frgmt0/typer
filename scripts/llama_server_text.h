// Pure text/JSON helpers for the Typer llama helper.
//
// Everything here is free of llama.cpp (and of any other) dependency on purpose:
// llama_server.cpp is one big translation unit with a main() and a hard link
// against libllama, which makes its string logic impossible to test. This header
// holds that logic so scripts/helper_tests.cpp can include it standalone and
// exercise it with clang++ alone (see scripts/run_helper_tests.sh).
//
// Everything is `inline` so both translation units can include it.

#ifndef TYPER_LLAMA_SERVER_TEXT_H
#define TYPER_LLAMA_SERVER_TEXT_H

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

// ---------------------------------------------------------------------------
// UTF-8
// ---------------------------------------------------------------------------

// Decode one UTF-8 scalar at s[i]. Strict: overlong encodings, surrogate halves,
// scalars above U+10FFFF, truncated sequences and stray continuation bytes are all
// rejected, so nothing invalid can be laundered back out as a "valid" scalar.
inline bool utf8_decode(const std::string &s, size_t i, uint32_t &cp, size_t &len) {
    if (i >= s.size()) return false;
    unsigned char b0 = (unsigned char)s[i];
    if (b0 < 0x80) { cp = b0; len = 1; return true; }
    size_t need;
    uint32_t v;
    if ((b0 & 0xE0) == 0xC0)      { need = 1; v = (uint32_t)(b0 & 0x1F); }
    else if ((b0 & 0xF0) == 0xE0) { need = 2; v = (uint32_t)(b0 & 0x0F); }
    else if ((b0 & 0xF8) == 0xF0) { need = 3; v = (uint32_t)(b0 & 0x07); }
    else return false;                                   // continuation byte / 5-6 byte lead
    if (i + need >= s.size()) return false;              // truncated
    for (size_t k = 1; k <= need; ++k) {
        unsigned char b = (unsigned char)s[i + k];
        if ((b & 0xC0) != 0x80) return false;
        v = (v << 6) | (uint32_t)(b & 0x3F);
    }
    if (need == 1 && v < 0x80) return false;             // overlong
    if (need == 2 && v < 0x800) return false;
    if (need == 3 && v < 0x10000) return false;
    if (v >= 0xD800 && v <= 0xDFFF) return false;        // surrogate half
    if (v > 0x10FFFF) return false;
    cp = v;
    len = need + 1;
    return true;
}

inline void utf8_append(std::string &out, uint32_t cp) {
    if (cp <= 0x7F) {
        out += (char)cp;
    } else if (cp <= 0x7FF) {
        out += (char)(0xC0 | (cp >> 6));
        out += (char)(0x80 | (cp & 0x3F));
    } else if (cp <= 0xFFFF) {
        out += (char)(0xE0 | (cp >> 12));
        out += (char)(0x80 | ((cp >> 6) & 0x3F));
        out += (char)(0x80 | (cp & 0x3F));
    } else {
        out += (char)(0xF0 | (cp >> 18));
        out += (char)(0x80 | ((cp >> 12) & 0x3F));
        out += (char)(0x80 | ((cp >> 6) & 0x3F));
        out += (char)(0x80 | (cp & 0x3F));
    }
}

// Scalars that must never reach the model's prompt nor the user's document.
// They carry no linguistic signal, and under greedy decoding a single one of them
// in the context is enough to make the model echo it forever (the arrow-key
// U+001C → "u001cu001c…" failure this gate exists to stop).
//   - C0 controls except tab / newline / carriage return
//   - DEL (U+007F) and the C1 block (U+0080–U+009F)
//   - private use (U+E000–U+F8FF and planes 15-16, which are private use + their
//     noncharacters) — font-private glyphs (Apple's  , Nerd Font icons) that OCR
//     and AX text can drag in
//   - U+FFFD, the replacement character: something already lost information here
// Legitimate multi-byte text (accents, CJK, emoji, ZWJ U+200D, VS16 U+FE0F) is
// deliberately untouched.
inline bool is_disallowed_scalar(uint32_t cp) {
    if (cp < 0x20) return !(cp == 0x09 || cp == 0x0A || cp == 0x0D);
    if (cp == 0x7F) return true;
    if (cp >= 0x80 && cp <= 0x9F) return true;
    if (cp >= 0xE000 && cp <= 0xF8FF) return true;
    if (cp == 0xFFFD) return true;
    if (cp >= 0xF0000) return true;
    return false;
}

// Invisible FORMAT characters (Unicode general category Cf) plus U+FEFF.
//
// These are a different problem from the scalars above. They are not corruption and they
// are not a model loop — they are what every real-world copy/paste drags in: a BOM at the
// front of a pasted line (by far the commonest pollutant in captured rows), a zero-width
// space from a web page, a bidi mark from a PDF. They carry no linguistic signal, they are
// invisible to the user, and the Swift side's TextSanitizer refuses text containing them
// outright — so leaving them in here meant the helper and the app disagreed about what
// "clean text" is, and a single pasted BOM silently disqualified everything downstream.
// The policy is therefore STRIP, never reject: the text around them is perfectly good.
//
// C++ has no unicodedata, so the category is an explicit range table. Two deliberate
// exceptions, both because they hold real text together:
//   - U+200D ZERO WIDTH JOINER: multi-person and profession emoji are built from it.
//   - U+E0020-U+E007F, the TAG block: the flag sequences for England, Scotland and Wales
//     are U+1F3F4 followed by tag letters and terminated by U+E007F. Stripping tags would
//     shred those flags, so the whole block is allowed rather than tracked statefully.
inline bool is_format_scalar(uint32_t cp) {
    if (cp == 0x200D) return false;                        // ZWJ: emoji glue
    if (cp >= 0xE0020 && cp <= 0xE007F) return false;      // tag block: flag sequences
    if (cp == 0x00AD) return true;                         // soft hyphen
    if (cp >= 0x0600 && cp <= 0x0605) return true;         // Arabic number signs
    if (cp == 0x061C) return true;                         // Arabic letter mark
    if (cp == 0x06DD || cp == 0x070F) return true;
    if (cp == 0x0890 || cp == 0x0891) return true;         // Arabic pound/piastre marks above
    if (cp == 0x08E2) return true;                         // Arabic disputed end of ayah
    if (cp == 0x180E) return true;                         // Mongolian vowel separator
    if (cp >= 0x200B && cp <= 0x200F) return true;         // ZWSP, ZWNJ, LRM, RLM
    if (cp >= 0x202A && cp <= 0x202E) return true;         // bidi embedding/override
    if (cp >= 0x2060 && cp <= 0x2064) return true;         // word joiner, invisible operators
    if (cp >= 0x2066 && cp <= 0x206F) return true;         // bidi isolates, deprecated formats
    if (cp == 0xFEFF) return true;                         // BOM / zero width no-break space
    if (cp >= 0xFFF9 && cp <= 0xFFFB) return true;         // interlinear annotation
    if (cp == 0x110BD || cp == 0x110CD) return true;       // Kaithi number signs
    if (cp >= 0x13430 && cp <= 0x1343F) return true;       // Egyptian hieroglyph formats
    if (cp >= 0x1BCA0 && cp <= 0x1BCA3) return true;       // shorthand format controls
    if (cp >= 0x1D173 && cp <= 0x1D17A) return true;       // musical beam/slur formats
    if (cp == 0xE0001) return true;                        // deprecated language tag
    return false;
}

// True if `s` holds any disallowed scalar OR any invalid UTF-8 byte. Format characters
// are deliberately NOT included: they are stripped, not grounds for rejection.
inline bool has_disallowed_scalar(const std::string &s) {
    size_t i = 0;
    while (i < s.size()) {
        uint32_t cp;
        size_t len;
        if (!utf8_decode(s, i, cp, len)) return true;
        if (is_disallowed_scalar(cp)) return true;
        i += len;
    }
    return false;
}

// Drop only the invisible format characters, keeping everything else — including invalid
// UTF-8 — byte-identical. This is the OUTPUT-side screen: a completion that happens to
// carry a zero-width space is a good completion with an invisible character in it, so it
// is cleaned and kept, while the hard scalars (C0/C1, private use, U+FFFD, invalid UTF-8)
// still make looks_bad_completion throw the whole thing away.
inline std::string strip_format_scalars(const std::string &s) {
    std::string out;
    out.reserve(s.size());
    size_t i = 0;
    while (i < s.size()) {
        uint32_t cp;
        size_t len;
        if (!utf8_decode(s, i, cp, len)) { out += s[i]; ++i; continue; }   // not ours to judge
        if (!is_format_scalar(cp)) out.append(s, i, len);
        i += len;
    }
    return out;
}

// Drop every disallowed scalar, every invisible format character and every invalid UTF-8
// byte, keeping everything else byte-identical. Second line of defence behind the JSON
// unescaper: whatever the transport does, the prompt only ever sees text. Clean text
// passes through untouched, byte for byte.
inline std::string strip_disallowed(const std::string &s) {
    std::string out;
    out.reserve(s.size());
    size_t i = 0;
    while (i < s.size()) {
        uint32_t cp;
        size_t len;
        if (!utf8_decode(s, i, cp, len)) { ++i; continue; }   // invalid byte: drop, resync
        if (!is_disallowed_scalar(cp) && !is_format_scalar(cp)) out.append(s, i, len);
        i += len;
    }
    return out;
}

// ---------------------------------------------------------------------------
// JSON reading
// ---------------------------------------------------------------------------

inline bool json_is_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

// s[i] is the opening quote; returns the index just past the closing quote, or
// s.size() when the literal is unterminated. Escapes are skipped as a pair so a
// `\"` never ends the scan early.
inline size_t json_skip_string(const std::string &s, size_t i) {
    for (++i; i < s.size(); ++i) {
        char c = s[i];
        if (c == '\\') { ++i; continue; }
        if (c == '"') return i + 1;
    }
    return s.size();
}

// Index of the first character of the value of TOP-LEVEL `key`, or npos.
//
// The old implementation was `s.find("\"key\"")`, which happily matched a key name
// that appeared inside a string VALUE — and `context` is arbitrary text the user
// typed, so `{"context":"\"suffix\": nope"}` made the helper read the user's prose
// as the suffix field. This walks the object instead: string literals are skipped
// wholesale and only names at depth 1 that are actually followed by ':' count.
inline size_t json_find_value(const std::string &s, const std::string &key) {
    size_t i = s.find('{');
    if (i == std::string::npos) return std::string::npos;
    int depth = 0;
    while (i < s.size()) {
        char c = s[i];
        if (c == '{' || c == '[') { ++depth; ++i; continue; }
        if (c == '}' || c == ']') { --depth; ++i; if (depth <= 0) break; continue; }
        if (c == '"') {
            size_t end = json_skip_string(s, i);
            if (depth == 1) {
                size_t j = end;
                while (j < s.size() && json_is_space(s[j])) ++j;
                if (j < s.size() && s[j] == ':') {
                    bool match = end - i == key.size() + 2 &&
                                 s.compare(i + 1, key.size(), key) == 0;
                    ++j;
                    while (j < s.size() && json_is_space(s[j])) ++j;
                    if (match) return j;
                    i = j;                       // continue scanning at the value
                    continue;
                }
            }
            i = end;
            continue;
        }
        ++i;
    }
    return std::string::npos;
}

// Read 4 hex digits at s[i] into `out`. False on truncation or a non-hex digit.
inline bool json_hex4(const std::string &s, size_t i, uint32_t &out) {
    if (i + 4 > s.size()) return false;
    uint32_t v = 0;
    for (size_t k = 0; k < 4; ++k) {
        char c = s[i + k];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= (uint32_t)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (uint32_t)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (uint32_t)(c - 'A' + 10);
        else return false;
    }
    out = v;
    return true;
}

// Decode the JSON string literal whose opening quote is at s[start].
//
// The previous hand-rolled version understood only \n \t \r \" \\ and fell through
// to `out += c` for everything else, so Swift's JSONEncoder output — which escapes
// every C0 control as \u001c and '/' as '\/' — arrived at the model as the literal
// ASCII text "u001c". Greedy decoding then continued it forever. This implements
// the whole grammar: \" \\ \/ \b \f \n \r \t and \uXXXX including surrogate pairs.
//
// Malformed input is dropped, never substituted: a lone/invalid surrogate is
// skipped (U+FFFD in a prompt is just one more junk token to condition on), and a
// truncated or non-hex \u escape ends the string there rather than leaking its raw
// bytes. Nothing ever reads past the end of the buffer.
inline std::string json_unescape(const std::string &s, size_t start) {
    std::string out;
    if (start >= s.size() || s[start] != '"') return out;
    size_t i = start + 1;
    while (i < s.size()) {
        char c = s[i];
        if (c == '"') break;
        if (c != '\\') { out += c; ++i; continue; }
        if (i + 1 >= s.size()) break;                       // trailing backslash
        char e = s[i + 1];
        i += 2;
        switch (e) {
            case '"':  out += '"';  break;
            case '\\': out += '\\'; break;
            case '/':  out += '/';  break;
            case 'b':  out += '\b'; break;
            case 'f':  out += '\f'; break;
            case 'n':  out += '\n'; break;
            case 'r':  out += '\r'; break;
            case 't':  out += '\t'; break;
            case 'u': {
                uint32_t cp;
                if (!json_hex4(s, i, cp)) return out;        // truncated/malformed: stop
                i += 4;
                if (cp >= 0xD800 && cp <= 0xDBFF) {          // high surrogate
                    uint32_t lo;
                    if (i + 1 < s.size() && s[i] == '\\' && s[i + 1] == 'u' &&
                        json_hex4(s, i + 2, lo) && lo >= 0xDC00 && lo <= 0xDFFF) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        i += 6;
                    } else {
                        break;                               // lone high surrogate: drop
                    }
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    break;                                   // lone low surrogate: drop
                }
                utf8_append(out, cp);
                break;
            }
            default: out += e; break;                        // unknown escape: keep the char
        }
    }
    return out;
}

inline std::string json_get_string(const std::string &s, const std::string &key) {
    size_t p = json_find_value(s, key);
    if (p == std::string::npos || p >= s.size() || s[p] != '"') return "";
    return json_unescape(s, p);
}

inline int json_get_int(const std::string &s, const std::string &key, int def) {
    size_t p = json_find_value(s, key);
    if (p == std::string::npos || p >= s.size()) return def;
    char *end = nullptr;
    long v = std::strtol(s.c_str() + p, &end, 10);
    return end == s.c_str() + p ? def : (int)v;
}

inline double json_get_double(const std::string &s, const std::string &key, double def) {
    size_t p = json_find_value(s, key);
    if (p == std::string::npos || p >= s.size()) return def;
    char *end = nullptr;
    double v = std::strtod(s.c_str() + p, &end);
    return end == s.c_str() + p ? def : v;
}

// ---------------------------------------------------------------------------
// JSON writing
// ---------------------------------------------------------------------------

inline std::string json_escape(const std::string &s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[7];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += (char)c;
                }
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Completion shaping + quality gates
// ---------------------------------------------------------------------------

inline std::string trim(std::string s) {
    while (!s.empty() && std::isspace((unsigned char)s.front())) s.erase(s.begin());
    while (!s.empty() && std::isspace((unsigned char)s.back())) s.pop_back();
    return s;
}

inline bool contains_special_fragment(const std::string &s) {
    return s.find("<|") != std::string::npos || s.find("|>") != std::string::npos || s.find("<turn") != std::string::npos;
}

inline std::string lower_ascii(std::string s) {
    for (char &c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

// Digit-group punctuation: the characters that make a run of digits look like one
// formatted number ("1,000,000,000", "192.168.0.1", "2024-01-01") rather than a loop.
inline bool is_number_punct(char c) {
    return c == '.' || c == ',' || c == '_' || c == '-' || c == ':' || c == '/';
}

// Is the repetition at [begin, end) part of a URL, a path or a hex literal? Those are the
// three places where a short unit legitimately repeats: "…/en/en/en/index.html" in a
// localised URL, "/api/v1/v1/v1" in a route, and "0xdeadbeefdeadbeefdeadbeef" in a dump.
//
// The exemption has to be narrow, because it DISABLES the loop detector. It used to walk
// out to whitespace and exempt the whole token the moment it saw one '/' anywhere in it,
// which is a hole the size of a bus: any space-free string containing a single slash was
// unprotected, so "foo/loooploooploooploop" and "ab/ab/ab/ab/ab/ab/" both sailed through.
// Two conditions instead, and both are about the RUN, not merely about its neighbourhood:
//   • the hex case requires the repeated run itself to be hex digits inside a 0x… token;
//   • the URL/path case requires the repeated UNIT to carry the structure ('/', '.' or
//     ':'), so the repeating thing is the path segmentation and not a word that happens to
//     sit next to a slash — and it caps out at six repetitions, because nothing legitimate
//     says the same segment six times in a row.
inline bool run_inside_uri_or_hex(const std::string &s, size_t begin, size_t end,
                                  size_t unit, size_t reps) {
    size_t lo = begin, hi = end;
    while (lo > 0 && !std::isspace((unsigned char)s[lo - 1])) --lo;
    while (hi < s.size() && !std::isspace((unsigned char)s[hi])) ++hi;
    const std::string token = s.substr(lo, hi - lo);
    bool hex_run = true;
    for (size_t k = begin; k < end && hex_run; ++k) hex_run = std::isxdigit((unsigned char)s[k]) != 0;
    if (hex_run && token.size() > 2 && token[0] == '0' && (token[1] == 'x' || token[1] == 'X')) return true;
    if (reps >= 6) return false;
    bool structured = false;
    for (size_t k = begin; k < begin + unit; ++k) {
        char c = s[k];
        if (c == '/' || c == '.' || c == ':') { structured = true; break; }
    }
    if (!structured) return false;
    return token.find('/') != std::string::npos;
}

// Space-free degenerate repetition: the same short unit hammered out over and over
// with no word breaks, which the space-delimited word check below structurally
// cannot see ("u001cu001cu001c…" is one "word"). Thresholds are picked to catch
// model loops without touching real language:
//   - unit 2-8 bytes, repeated back to back
//   - a SHORT unit (<= 3 bytes) needs >= 4 repetitions covering >= 9 bytes. Three
//     repetitions of a short unit is not a loop, it is ordinary text and ordinary
//     structure: "abcabcabc", "lollollol", "en/en/en", "/v1/v1/v1" are all exactly that
//     shape, and no counting rule can tell them apart — so the bar moves to four, where
//     "hahahahaha" and "nononononono" live and none of those do.
//   - a LONGER unit (>= 4 bytes) needs >= 3 repetitions covering >= 12 bytes; the
//     coincidence of a 4+ byte string landing three times in a row is already unlikely.
//   - the unit must contain no whitespace — space-delimited repetition is the other
//     check's job, and requiring space-free keeps "cha cha cha" out of it
//   - the unit must be mostly (>= 2/3) ASCII alphanumeric. A unit that is half
//     punctuation is an alternation, i.e. formatting: "a-b-a-b-a-b-a-b" is a list, while
//     "100%100%100%" is a loop, and both are 4-byte units repeated three times over 12
//     bytes. Density is the only thing that separates them. It also keeps "...",
//     "!!!!!!!!!!", "-=-=-=-=" and runs of repeated emoji out, since they have no ASCII
//     alphanumeric at all.
//   - a unit made only of digits and digit-group punctuation is skipped, so
//     "$1,000,000,000 in funding" (",000" x3) survives
//   - a run inside a URL, a path or a hex literal is skipped outright (above)
// "banana", "Mississippi" and "bookkeeper" are all below these thresholds.
inline bool has_repeated_run(const std::string &s) {
    const size_t n = s.size();
    for (size_t unit = 2; unit <= 8; ++unit) {
        const size_t min_reps = unit <= 3 ? 4 : 3;
        const size_t min_bytes = unit <= 3 ? 9 : 12;
        if (n < unit * min_reps) break;
        for (size_t start = 0; start + unit * min_reps <= n; ++start) {
            size_t alnum = 0;
            bool numeric_only = true, spaced = false;
            for (size_t k = 0; k < unit; ++k) {
                char c = s[start + k];
                unsigned char u = (unsigned char)c;
                if (std::isspace(u)) { spaced = true; break; }
                if (std::isalnum(u)) alnum++;
                if (!std::isdigit(u) && !is_number_punct(c)) numeric_only = false;
            }
            if (spaced || alnum == 0 || numeric_only) continue;
            if (alnum * 3 < unit * 2) continue;             // less than 2/3 alphanumeric
            size_t reps = 1;
            while (start + unit * (reps + 1) <= n &&
                   s.compare(start + unit * reps, unit, s, start, unit) == 0) ++reps;
            if (reps < min_reps || reps * unit < min_bytes) continue;
            if (run_inside_uri_or_hex(s, start, start + reps * unit, unit, reps)) continue;
            return true;
        }
    }
    return false;
}

inline bool looks_bad_completion(const std::string &s) {
    // Output gate for control / private-use / invalid-UTF-8 scalars. Whatever put
    // one in the model's mouth, it must not reach the user's document.
    if (has_disallowed_scalar(s)) return true;
    std::string t = lower_ascii(trim(s));
    if (t.empty()) return true;
    if (contains_special_fragment(t)) return true;
    if (t == "cont" || t == "continuation" || t == "text:" || t.rfind("continuation:", 0) == 0 || t.rfind("text:", 0) == 0) return true;
    if (t.find("as an ai") != std::string::npos || t.find("i'm sorry") != std::string::npos) return true;
    if (has_repeated_run(t)) return true;
    if (t.size() > 2) {
        size_t p = t.find(' ');
        if (p != std::string::npos) {
            std::string w = t.substr(0, p);
            int repeats = 0;
            size_t off = 0;
            while (off < t.size()) {
                if (t.compare(off, w.size(), w) == 0) repeats++;
                size_t next = t.find(' ', off);
                if (next == std::string::npos) break;
                off = next + 1;
            }
            if (repeats >= 4) return true;
        }
    }
    return false;
}

// Last non-space char of the context (0 if none) — lets the numeric gate tell
// "the discount is " (prose) from "...is 5" (user mid-number).
inline char last_nonspace(const std::string &s) {
    for (auto it = s.rbegin(); it != s.rend(); ++it)
        if (!std::isspace((unsigned char)*it)) return *it;
    return 0;
}

// A completion that is itself just a number, or LEADS with a percentage, is almost
// always pollution from on-screen UI chrome (zoom "100%", battery, progress, a stat
// readout) leaking through the context — not a real continuation of what the user is
// writing. Drop it, UNLESS the user is mid-number (context ends in a digit), where
// "5" -> "0%" or "12" -> ".5" is a legitimate continuation. This is the catch-all for
// the "first suggestion is 100% / 90%" complaint regardless of where the digits came
// from. `s` is the already-shaped completion (may have one leading space).
inline bool is_orphan_number(const std::string &s, const std::string &context) {
    std::string t = trim(s);
    if (t.empty()) return false;
    if (std::isdigit((unsigned char)last_nonspace(context))) return false;  // user is mid-number
    size_t i = 0;
    if (t[i] == '$') i++;
    bool saw_digit = false;
    while (i < t.size() && (std::isdigit((unsigned char)t[i]) || t[i] == '.' || t[i] == ',')) {
        if (std::isdigit((unsigned char)t[i])) saw_digit = true;
        i++;
    }
    if (!saw_digit) return false;                    // no actual number (e.g. "...", ".", "$")
    bool pct = (i < t.size() && t[i] == '%');
    if (pct) i++;
    std::string rest = trim(t.substr(i));
    // Leading percentage ("90% off") or a bare number with nothing after ("100", "3.5").
    return pct || rest.empty();
}

inline std::string limit_words(const std::string &s, int max_words) {
    std::string out;
    int words = 0;
    bool in_word = false;
    for (char c : s) {
        out += c;
        if (std::isspace((unsigned char)c)) {
            if (in_word) {
                words++;
                if (words >= max_words) break;
            }
            in_word = false;
        } else {
            in_word = true;
        }
    }
    if (in_word) words++;
    return trim(out);
}

// Remove HTML/XML-like tags (<em>, </strong>, <br/>, ...) that small models
// sometimes emit in prose. A '<' that is not followed by a letter or '/' (e.g.
// "a < b") is left intact, so code/math comparisons survive.
inline std::string strip_html_tags(const std::string &s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size();) {
        if (s[i] == '<' && i + 1 < s.size() &&
            (s[i + 1] == '/' || std::isalpha((unsigned char)s[i + 1]))) {
            size_t close = s.find('>', i + 1);
            if (close != std::string::npos && close - i <= 40) { i = close + 1; continue; }
        }
        out += s[i++];
    }
    return out;
}

// Drop a trailing incomplete UTF-8 sequence. Token streaming can split a multibyte
// character across two tokens; emitting the half would produce invalid UTF-8 in a
// {"p":...} JSON line and the Swift side would reject the whole partial.
inline std::string utf8_safe(const std::string &s) {
    size_t len = s.size();
    if (len == 0) return s;
    size_t i = len, cont = 0;
    while (i > 0 && ((unsigned char)s[i - 1] & 0xC0) == 0x80 && cont < 3) { i--; cont++; }
    if (i == 0) return s;
    unsigned char lead = (unsigned char)s[i - 1];
    size_t expected = (lead & 0x80) == 0x00 ? 1 :
                      (lead & 0xE0) == 0xC0 ? 2 :
                      (lead & 0xF0) == 0xE0 ? 3 :
                      (lead & 0xF8) == 0xF0 ? 4 : 0;
    if (expected == 0) return s;                 // invalid lead byte; leave as-is
    if (len - (i - 1) < expected) return s.substr(0, i - 1);  // incomplete tail → drop
    return s;
}

inline std::string first_line_clean(std::string s) {
    auto cut_marker = [&](const std::string &m) {
        size_t p = s.find(m);
        while (p != std::string::npos) { s.erase(p, m.size()); p = s.find(m); }
    };
    cut_marker("<|channel>thought<channel|>");
    cut_marker("<|channel>final<channel|>");
    cut_marker("<|channel>");
    cut_marker("<channel|>");
    cut_marker("<|think|>");
    cut_marker("<turn|>");
    cut_marker("<|turn>model");
    cut_marker("<|turn>user");
    s = strip_html_tags(s);
    return trim(s);
}

inline std::string remove_echo(std::string out, const std::string &context) {
    out = trim(out);
    for (const std::string &label : {"Continuation:", "Next words:", "Insert:", "Completion:"}) {
        size_t lp = out.rfind(label);
        if (lp != std::string::npos) out = trim(out.substr(lp + label.size()));
    }
    std::string ctx = trim(context);
    if (ctx.empty()) return out;
    size_t p = out.find(ctx);
    if (p != std::string::npos) {
        return trim(out.substr(p + ctx.size()));
    }
    for (size_t n = std::min<size_t>(ctx.size(), 120); n > 12; --n) {
        std::string suffix = ctx.substr(ctx.size() - n);
        p = out.find(suffix);
        if (p != std::string::npos) return trim(out.substr(p + suffix.size()));
    }
    return out;
}

// Tail window with a STABLE start, mirroring the Swift side. A plain "last N bytes"
// cut slides forward with every request, so the prompt's first tokens differ each
// time and prepare_prompt's KV prefix reuse never fires — every request re-decodes
// the whole prompt. Snapping the cut to a text boundary keeps the prompt prefix
// identical across requests until the boundary leaves the search range.
inline std::string stable_tail(const std::string &s, size_t max_chars) {
    if (s.size() <= max_chars) return s;
    std::string tail = s.substr(s.size() - max_chars);
    size_t strong = std::string::npos, space = std::string::npos;
    for (size_t i = 0; i < max_chars / 2; ++i) {
        char c = tail[i];
        if (c == '\n' || c == '\r') { strong = i; break; }
        if (i > 0 && c == ' ' && (tail[i-1] == '.' || tail[i-1] == '!' || tail[i-1] == '?')) { strong = i; break; }
        if (space == std::string::npos && c == ' ') space = i;
    }
    size_t cut = strong != std::string::npos ? strong : space;
    if (cut == std::string::npos || cut + 1 >= tail.size()) return tail;
    return tail.substr(cut + 1);
}

#endif  // TYPER_LLAMA_SERVER_TEXT_H
