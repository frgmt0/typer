// Unit tests for the Typer helper's pure text/JSON layer (scripts/llama_server_text.h).
//
// No llama.cpp, no model, no process: just clang++ and this file.
//   bash scripts/run_helper_tests.sh
//
// The JSON fixtures marked "captured from Foundation" are the literal bytes
// Foundation's JSONEncoder produced for the Swift app's request struct — that is
// the only encoder that ever talks to this parser, and its escaping (\u001c for C0
// controls, \/ for slash, \b and \f, raw UTF-8 for everything non-ASCII) is exactly
// what the old hand-rolled unescaper got wrong.

#include "llama_server_text.h"

#include <cstdio>
#include <string>

static int g_checks = 0;
static int g_failures = 0;

// Render a string with non-printables escaped, so a failure message is readable.
static std::string show(const std::string &s) {
    std::string o;
    for (unsigned char c : s) {
        if (c >= 0x20 && c < 0x7F) {
            o += (char)c;
        } else {
            char b[8];
            snprintf(b, sizeof(b), "\\x%02x", c);
            o += b;
        }
    }
    return o;
}

static void check_eq(int line, const char *expr, const std::string &got, const std::string &want) {
    g_checks++;
    if (got == want) return;
    g_failures++;
    printf("FAIL line %d: %s\n      got:  \"%s\"\n      want: \"%s\"\n",
           line, expr, show(got).c_str(), show(want).c_str());
}

static void check_int(int line, const char *expr, long got, long want) {
    g_checks++;
    if (got == want) return;
    g_failures++;
    printf("FAIL line %d: %s\n      got:  %ld\n      want: %ld\n", line, expr, got, want);
}

static void check_bool(int line, const char *expr, bool got, bool want) {
    g_checks++;
    if (got == want) return;
    g_failures++;
    printf("FAIL line %d: %s is %s, want %s\n", line, expr,
           got ? "true" : "false", want ? "true" : "false");
}

#define CHECK_EQ(a, b)    check_eq(__LINE__, #a, (a), (b))
#define CHECK_INT(a, b)   check_int(__LINE__, #a, (long)(a), (long)(b))
#define CHECK_TRUE(a)     check_bool(__LINE__, #a, (a), true)
#define CHECK_FALSE(a)    check_bool(__LINE__, #a, (a), false)

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

// Captured from Foundation, byte for byte:
//   struct R: Codable { let context: String }
//   let s = "a\u{1C}b\u{1F}\tc\nd\"e\\f/g é — 😀 👨‍👩‍👧 \u{7F}\u{0008}\u{000C}"
//   print(String(data: try! JSONEncoder().encode(R(context: s)), encoding: .utf8)!)
static const char *kSwiftLine =
    "{\"context\":\"a\\u001cb\\u001f\\tc\\nd\\\"e\\\\f\\/g "
    "\xc3\xa9 \xe2\x80\x94 \xf0\x9f\x98\x80 "
    "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7 "
    "\x7f\\b\\f\"}";

// What that line means. Note U+007F arrives RAW (JSON does not require escaping it),
// so only the scalar screen can catch it.
static std::string swift_decoded() {
    return std::string("a\x1c") + "b\x1f" +
           "\tc\nd\"e\\f/g \xc3\xa9 \xe2\x80\x94 \xf0\x9f\x98\x80 "
           "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7 "
           "\x7f\b\f";
}

// The same text with every disallowed scalar gone; every legitimate character
// (tab, newline, quote, backslash, slash, é, em dash, astral emoji, ZWJ family) stays.
static std::string swift_stripped() {
    return "ab\tc\nd\"e\\f/g \xc3\xa9 \xe2\x80\x94 \xf0\x9f\x98\x80 "
           "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7 ";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

static void test_swift_roundtrip() {
    std::string ctx = json_get_string(kSwiftLine, "context");
    CHECK_EQ(ctx, swift_decoded());

    // The C2 regression itself: the old parser turned \u001c into the literal text
    // "u001c", which greedy decoding then repeated forever.
    CHECK_TRUE(ctx.find("u001c") == std::string::npos);
    CHECK_TRUE(ctx.find('\x1c') != std::string::npos);
    // "\/" must decode to "/", not to "\/".
    CHECK_TRUE(ctx.find("\\/") == std::string::npos);
    CHECK_TRUE(ctx.find("f/g") != std::string::npos);

    // What actually reaches the prompt after the scalar screen.
    CHECK_EQ(strip_disallowed(ctx), swift_stripped());
    CHECK_FALSE(has_disallowed_scalar(strip_disallowed(ctx)));
}

static void test_escapes() {
    CHECK_EQ(json_get_string("{\"k\":\"a\\\"b\"}", "k"), "a\"b");
    CHECK_EQ(json_get_string("{\"k\":\"a\\\\b\"}", "k"), "a\\b");
    CHECK_EQ(json_get_string("{\"k\":\"a\\/b\"}", "k"), "a/b");
    CHECK_EQ(json_get_string("{\"k\":\"a\\bb\"}", "k"), std::string("a\b") + "b");
    CHECK_EQ(json_get_string("{\"k\":\"a\\fb\"}", "k"), std::string("a\f") + "b");
    CHECK_EQ(json_get_string("{\"k\":\"a\\nb\"}", "k"), "a\nb");
    CHECK_EQ(json_get_string("{\"k\":\"a\\rb\"}", "k"), "a\rb");
    CHECK_EQ(json_get_string("{\"k\":\"a\\tb\"}", "k"), "a\tb");
    // \uXXXX, BMP, both hex cases.
    CHECK_EQ(json_get_string("{\"k\":\"\\u00e9\"}", "k"), "\xc3\xa9");          // é
    CHECK_EQ(json_get_string("{\"k\":\"\\u00E9\"}", "k"), "\xc3\xa9");
    CHECK_EQ(json_get_string("{\"k\":\"\\u4e2d\"}", "k"), "\xe4\xb8\xad");      // 中
    CHECK_EQ(json_get_string("{\"k\":\"x\\u001cy\"}", "k"), std::string("x\x1c") + "y");
    // Surrogate pair -> one astral scalar (other JSON producers escape emoji this way).
    CHECK_EQ(json_get_string("{\"k\":\"\\ud83d\\ude00\"}", "k"), "\xf0\x9f\x98\x80");  // 😀
    // Unknown escape: keep the escaped character itself.
    CHECK_EQ(json_get_string("{\"k\":\"a\\qb\"}", "k"), "aqb");
}

static void test_malformed_and_truncated() {
    // Truncated \u escapes: decode what is known, never read past the buffer and
    // never leak the raw "u00" text into the prompt.
    CHECK_EQ(json_get_string("{\"k\":\"ab\\u00", "k"), "ab");
    CHECK_EQ(json_get_string("{\"k\":\"ab\\u", "k"), "ab");
    CHECK_EQ(json_get_string("{\"k\":\"ab\\", "k"), "ab");
    CHECK_EQ(json_get_string("{\"k\":\"ab", "k"), "ab");
    CHECK_EQ(json_get_string("{\"k\":\"", "k"), "");
    CHECK_EQ(json_get_string("{\"k\":", "k"), "");
    CHECK_EQ(json_get_string("{\"k\"", "k"), "");
    CHECK_EQ(json_get_string("", "k"), "");
    // Non-hex digits in a \u escape: stop there rather than emit "ZZZZ".
    CHECK_EQ(json_get_string("{\"k\":\"ab\\uZZZZcd\"}", "k"), "ab");
    // Lone surrogates are dropped, not turned into U+FFFD (a replacement char in a
    // prompt is just one more junk token for the model to condition on).
    CHECK_EQ(json_get_string("{\"k\":\"a\\ud83db\"}", "k"), "ab");
    CHECK_EQ(json_get_string("{\"k\":\"a\\udc00b\"}", "k"), "ab");
    CHECK_EQ(json_get_string("{\"k\":\"a\\ud83d\\ud83db\"}", "k"), "ab");
    CHECK_EQ(json_get_string("{\"k\":\"a\\ud83d\"}", "k"), "a");
    // A high surrogate followed by a truncated low one.
    CHECK_EQ(json_get_string("{\"k\":\"a\\ud83d\\ude", "k"), "a");
}

// A pipe can hand the helper a half-written line at any byte. Every prefix of a real
// request must parse without reading past the end and without leaking escape text.
// (Run this file under -fsanitize=address,undefined to check the first half properly.)
static void test_truncation_sweep() {
    const std::string full = kSwiftLine;
    bool clean = true;
    for (size_t n = 0; n <= full.size(); ++n) {
        std::string p = full.substr(0, n);
        std::string v = json_get_string(p, "context");
        (void)json_get_string(p, "suffix");
        (void)json_get_int(p, "max_words", 7);
        (void)json_get_double(p, "lexicon_bias", 0.5);
        if (v.find("u001c") != std::string::npos || v.find("\\u") != std::string::npos) clean = false;
        if (has_disallowed_scalar(strip_disallowed(v))) clean = false;
    }
    check_bool(__LINE__, "truncation sweep produces clean text", clean, true);
}

static void test_key_lookup() {
    const char *line =
        "{\"task\":\"complete\",\"context\":\"he said \\\"suffix\\\": nope\","
        "\"max_words\":7,\"lexicon_bias\":0.25,\"suffix\":\"real tail\"}";
    CHECK_EQ(json_get_string(line, "task"), "complete");
    CHECK_EQ(json_get_string(line, "context"), "he said \"suffix\": nope");
    // The key name inside the context VALUE must not shadow the real field.
    CHECK_EQ(json_get_string(line, "suffix"), "real tail");
    CHECK_INT(json_get_int(line, "max_words", 7), 7);
    CHECK_INT(json_get_int(line, "missing", 42), 42);
    CHECK_TRUE(json_get_double(line, "lexicon_bias", 0.5) == 0.25);
    CHECK_TRUE(json_get_double(line, "missing", 0.5) == 0.5);
    // A missing / null / nested key yields the empty string, as before.
    CHECK_EQ(json_get_string(line, "mode"), "");
    CHECK_EQ(json_get_string("{\"suffix\":null}", "suffix"), "");
    CHECK_EQ(json_get_string("{\"a\":{\"context\":\"nested\"}}", "context"), "");
    // Whitespace around the colon and value.
    CHECK_EQ(json_get_string("{ \"context\" : \"v\" }", "context"), "v");
    CHECK_INT(json_get_int("{ \"n\" : -12 }", "n", 0), -12);
    // A prefix of a real key must not match it.
    CHECK_EQ(json_get_string("{\"contexts\":\"no\",\"context\":\"yes\"}", "context"), "yes");
}

static void test_json_escape_roundtrip() {
    // Everything the helper writes back must survive a strict re-read.
    const std::string samples[] = {
        swift_decoded(),
        std::string("tab\there\nnew \"quoted\" \\ back /slash"),
        std::string("\x01\x02\x03") + "\x7f \xc3\xa9 \xf0\x9f\x98\x80",
        std::string(""),
    };
    for (const std::string &s : samples) {
        std::string line = "{\"text\":\"" + json_escape(s) + "\"}";
        CHECK_EQ(json_get_string(line, "text"), s);
    }
    // Control characters must go out as \uXXXX, never raw.
    CHECK_EQ(json_escape(std::string("a\x1c") + "b"), "a\\u001cb");
    CHECK_EQ(json_escape(std::string("a\b\f") + "b"), "a\\u0008\\u000cb");
}

static void test_strip_disallowed() {
    // Removed.
    CHECK_EQ(strip_disallowed(std::string("a\x00", 2) + "b"), "ab");            // NUL
    CHECK_EQ(strip_disallowed(std::string("a\x1c") + "b"), "ab");               // C0 (arrow key)
    CHECK_EQ(strip_disallowed(std::string("a\x1f") + "b"), "ab");
    CHECK_EQ(strip_disallowed(std::string("a\b\f\x1b") + "b"), "ab");           // BS, FF, ESC
    CHECK_EQ(strip_disallowed(std::string("a\x7f") + "b"), "ab");               // DEL
    CHECK_EQ(strip_disallowed("a\xc2\x85" "b"), "ab");                          // C1 U+0085 NEL
    CHECK_EQ(strip_disallowed("a\xc2\x9f" "b"), "ab");                          // C1 U+009F
    CHECK_EQ(strip_disallowed("a\xee\x80\x80" "b"), "ab");                      // PUA U+E000
    CHECK_EQ(strip_disallowed("a\xef\xa3\xbf" "b"), "ab");                      // PUA U+F8FF (Apple logo)
    CHECK_EQ(strip_disallowed("a\xf3\xb0\x80\x80" "b"), "ab");                  // plane 15 U+F0000
    CHECK_EQ(strip_disallowed("a\xf4\x80\x80\x80" "b"), "ab");                  // plane 16 U+100000
    CHECK_EQ(strip_disallowed("a\xef\xbf\xbd" "b"), "ab");                      // U+FFFD
    // Invalid UTF-8 is dropped byte-wise, and the valid text around it survives.
    CHECK_EQ(strip_disallowed("a\xff" "b"), "ab");                              // impossible byte
    CHECK_EQ(strip_disallowed("a\x80" "b"), "ab");                              // stray continuation
    CHECK_EQ(strip_disallowed("a\xc3" "b"), "ab");                              // truncated 2-byte lead
    CHECK_EQ(strip_disallowed("a\xc3"), "a");                                   // truncated at end
    CHECK_EQ(strip_disallowed("a\xc0\xaf" "b"), "ab");                          // overlong '/'
    CHECK_EQ(strip_disallowed("a\xed\xa0\x80" "b"), "ab");                      // CESU-8 surrogate

    // Kept, byte for byte.
    CHECK_EQ(strip_disallowed("plain ascii"), "plain ascii");
    CHECK_EQ(strip_disallowed("tab\there\r\nline"), "tab\there\r\nline");
    CHECK_EQ(strip_disallowed("caf\xc3\xa9 na\xc3\xafve \xe2\x80\x94 \xc3\x9f"),
             "caf\xc3\xa9 na\xc3\xafve \xe2\x80\x94 \xc3\x9f");
    CHECK_EQ(strip_disallowed("\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e"), "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e");
    CHECK_EQ(strip_disallowed("\xf0\x9f\x98\x80"), "\xf0\x9f\x98\x80");         // astral emoji
    CHECK_EQ(strip_disallowed("\xe2\x9d\xa4\xef\xb8\x8f"), "\xe2\x9d\xa4\xef\xb8\x8f");  // ❤ + VS16
    CHECK_EQ(strip_disallowed("\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7"),
             "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7");  // ZWJ family

    // has_disallowed_scalar agrees with strip_disallowed on both sides.
    CHECK_TRUE(has_disallowed_scalar(std::string("a\x1c") + "b"));
    CHECK_TRUE(has_disallowed_scalar("a\xef\xbf\xbd"));
    CHECK_TRUE(has_disallowed_scalar("a\xff"));
    CHECK_TRUE(has_disallowed_scalar("\xf0\x9f\x98"));                          // truncated emoji
    CHECK_FALSE(has_disallowed_scalar(""));
    CHECK_FALSE(has_disallowed_scalar("normal text, with punctuation!"));
    CHECK_FALSE(has_disallowed_scalar("caf\xc3\xa9\tand\na newline"));
    CHECK_FALSE(has_disallowed_scalar("\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9"));
}

// F17: invisible format characters (Cf) + U+FEFF. The Swift side's TextSanitizer refuses
// text containing any of them, so the helper has to agree — but the right answer is to
// STRIP them, not to reject the text around them: a BOM at the front of a pasted line is
// the single commonest pollutant in real captured rows, and the prose after it is fine.
static void test_format_scalars() {
    // The England flag: U+1F3F4 + tag letters "gbeng" + the cancel tag U+E007F. The tag
    // block IS Cf, so a naive category strip shreds this flag — hence the exemption.
    const std::string england =
        "\xf0\x9f\x8f\xb4\xf3\xa0\x81\xa7\xf3\xa0\x81\xa2\xf3\xa0\x81\xa5"
        "\xf3\xa0\x81\xae\xf3\xa0\x81\xa7\xf3\xa0\x81\xbf";

    // Stripped by both screens.
    CHECK_EQ(strip_disallowed("\xef\xbb\xbfhello"), "hello");                   // BOM (the real-world case)
    CHECK_EQ(strip_disallowed("a\xe2\x80\x8b" "b"), "ab");                      // U+200B ZWSP
    CHECK_EQ(strip_disallowed("a\xe2\x80\x8e" "b"), "ab");                      // U+200E LRM
    CHECK_EQ(strip_disallowed("a\xe2\x80\x8f" "b"), "ab");                      // U+200F RLM
    CHECK_EQ(strip_disallowed("a\xe2\x80\xae" "b"), "ab");                      // U+202E RLO
    CHECK_EQ(strip_disallowed("a\xe2\x81\xa0" "b"), "ab");                      // U+2060 word joiner
    CHECK_EQ(strip_disallowed("a\xc2\xad" "b"), "ab");                          // U+00AD soft hyphen
    CHECK_EQ(strip_disallowed("a\xf3\xa0\x80\x81" "b"), "ab");                  // U+E0001 language tag
    CHECK_EQ(strip_disallowed("a\xe0\xa2\x90" "b"), "ab");                      // U+0890 Arabic pound mark
    CHECK_EQ(strip_disallowed("a\xe0\xa2\x91" "b"), "ab");                      // U+0891 Arabic piastre mark
    CHECK_TRUE(is_format_scalar(0x0890));
    CHECK_TRUE(is_format_scalar(0x0891));
    // The tag block is the one Cf range both sides deliberately allow (see TextSanitizer's
    // `isEmojiFormatException`); U+E0001 sits just below it and is not exempt.
    CHECK_FALSE(is_format_scalar(0xE0020));
    CHECK_FALSE(is_format_scalar(0xE007F));
    CHECK_TRUE(is_format_scalar(0xE0001));
    CHECK_EQ(strip_format_scalars("\xef\xbb\xbf going to the store"), " going to the store");
    CHECK_EQ(strip_format_scalars("a\xe2\x80\x8b" "b"), "ab");

    // Kept, byte for byte: the two exemptions plus everything that was never at issue.
    CHECK_EQ(strip_disallowed("\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9"),
             "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9");                   // ZWJ couple
    CHECK_EQ(strip_disallowed(england), england);                               // flag tag sequence
    CHECK_EQ(strip_format_scalars(england), england);
    CHECK_EQ(strip_format_scalars("\xe2\x9d\xa4\xef\xb8\x8f"), "\xe2\x9d\xa4\xef\xb8\x8f");  // VS16

    // The prompt contract: clean text is byte-identical through both screens.
    const std::string clean[] = {
        "plain ascii", "tab\there\r\nline", "caf\xc3\xa9 na\xc3\xafve \xe2\x80\x94 \xc3\x9f",
        "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", "\xf0\x9f\x98\x80", "", "a < b, not a tag",
    };
    for (const std::string &s : clean) {
        CHECK_EQ(strip_disallowed(s), s);
        CHECK_EQ(strip_format_scalars(s), s);
    }

    // Format characters are NOT a reason to reject: has_disallowed_scalar (the output
    // gate's hard screen) ignores them, and strip_format_scalars leaves the hard scalars
    // and invalid bytes alone for it to catch.
    CHECK_FALSE(has_disallowed_scalar("\xef\xbb\xbf" "text"));
    CHECK_FALSE(has_disallowed_scalar(england));
    CHECK_EQ(strip_format_scalars(std::string("a\x1c") + "b"), std::string("a\x1c") + "b");
    CHECK_EQ(strip_format_scalars("a\xff" "b"), "a\xff" "b");
    CHECK_TRUE(has_disallowed_scalar(strip_format_scalars(std::string("a\x1c") + "b")));
}

static void test_repeated_run() {
    // Positives: model loops with no spaces to break them up.
    CHECK_TRUE(has_repeated_run("u001cu001cu001c"));
    CHECK_TRUE(has_repeated_run("u001fu001fu001f"));
    CHECK_TRUE(has_repeated_run("u001cu001cu001cu001c and more"));
    CHECK_TRUE(has_repeated_run("hahahahaha"));
    CHECK_TRUE(has_repeated_run("abababababab"));
    CHECK_TRUE(has_repeated_run("aaaaaaaaaa"));
    CHECK_TRUE(has_repeated_run("lollollollol"));
    CHECK_TRUE(has_repeated_run("the answer is nononononono"));
    CHECK_TRUE(has_repeated_run("100%100%100%"));

    // Negatives: ordinary language and formatting.
    CHECK_FALSE(has_repeated_run(""));
    CHECK_FALSE(has_repeated_run("banana"));
    CHECK_FALSE(has_repeated_run("mississippi"));
    CHECK_FALSE(has_repeated_run("bookkeeper committee successfully"));
    CHECK_FALSE(has_repeated_run("hahaha"));
    CHECK_FALSE(has_repeated_run("cha cha cha"));
    CHECK_FALSE(has_repeated_run("ha ha ha ha"));
    CHECK_FALSE(has_repeated_run("the quick brown fox jumps over"));
    CHECK_FALSE(has_repeated_run("..."));
    CHECK_FALSE(has_repeated_run("!!!!!!!!!!"));
    CHECK_FALSE(has_repeated_run("-=-=-=-=-=-="));
    CHECK_FALSE(has_repeated_run("......."));
    CHECK_FALSE(has_repeated_run("$1,000,000,000 in funding"));
    CHECK_FALSE(has_repeated_run("192.168.100.100"));
    CHECK_FALSE(has_repeated_run("2024-01-01 00:00:00"));
    // Non-ASCII runs are deliberately exempt (the unit needs an ASCII alphanumeric):
    // repeated emoji and repeated accented letters are things people actually type,
    // and the scalar screen already covers the junk that matters.
    CHECK_FALSE(has_repeated_run("\xf0\x9f\x98\x80\xf0\x9f\x98\x80\xf0\x9f\x98\x80"));  // 😀😀😀
    CHECK_FALSE(has_repeated_run("oh\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9"));        // ééééé
    CHECK_FALSE(has_repeated_run(" to the meeting tomorrow morning"));
    CHECK_FALSE(has_repeated_run("aaa"));
    CHECK_FALSE(has_repeated_run("dada"));

    // F16 false positives. All five were being thrown away as "model loops".
    //
    // URLs, routes and hex dumps repeat short units for structural reasons, so the token
    // holding the run is exempted when it looks like one.
    CHECK_FALSE(has_repeated_run("https://example.com/en/en/en/index.html"));
    CHECK_FALSE(has_repeated_run("http://localhost:8080/api/v1/v1/v1"));
    CHECK_FALSE(has_repeated_run("0xdeadbeefdeadbeefdeadbeef"));
    CHECK_FALSE(has_repeated_run("see 0xdeadbeefdeadbeefdeadbeef in the dump"));
    // Three repetitions of a short unit is ordinary text, not a loop — "abcabcabc" and
    // "lollollol" are the same shape and nothing can separate them, so four is the bar.
    CHECK_FALSE(has_repeated_run("abcabcabc"));
    CHECK_FALSE(has_repeated_run("lollollol"));
    // A half-punctuation unit is an alternation (a list, a key sequence), not a loop —
    // which is exactly what separates it from "100%100%100%", byte counts being identical.
    CHECK_FALSE(has_repeated_run("a-b-a-b-a-b-a-b"));
    CHECK_FALSE(has_repeated_run("x=y=x=y=x=y=x=y="));
    // …and the exemptions must not become a hiding place: a genuine loop is still caught
    // when it merely happens to sit next to punctuation or a long unit.
    CHECK_TRUE(has_repeated_run("abcabcabcabc"));
    CHECK_TRUE(has_repeated_run("deadbeefdeadbeefdeadbeef"));

    // The URI exemption used to walk out to whitespace and exempt the WHOLE token on one
    // '/' anywhere in it, which switched the detector off for any space-free string
    // containing a slash. The structure now has to be in the repeated unit itself, and six
    // repetitions are never exempt whatever they are made of.
    CHECK_TRUE(has_repeated_run("ab/ab/ab/ab/ab/ab/"));          // 6 reps: a loop, slashes or not
    CHECK_TRUE(has_repeated_run("foo/loooploooploooploop"));     // the unit carries no structure
    CHECK_TRUE(has_repeated_run("https://x.com/loooploooploooploop"));
    // …while the real URL/path/hex shapes the exemption exists for still survive.
    CHECK_FALSE(has_repeated_run("https://example.com/en/en/en/index.html"));
    CHECK_FALSE(has_repeated_run("http://localhost:8080/api/v1/v1/v1"));
    CHECK_FALSE(has_repeated_run("0xdeadbeefdeadbeefdeadbeef"));
}

static void test_output_gate() {
    // Rejected.
    CHECK_TRUE(looks_bad_completion(""));
    CHECK_TRUE(looks_bad_completion("   "));
    CHECK_TRUE(looks_bad_completion(std::string(" the arrow\x1c") + " key"));   // C0 scalar
    CHECK_TRUE(looks_bad_completion(" apple\xef\xbf\xbd"));                     // U+FFFD
    CHECK_TRUE(looks_bad_completion(" apple\xff"));                            // invalid UTF-8
    CHECK_TRUE(looks_bad_completion(" \xef\xa3\xbf logo"));                     // private use
    CHECK_TRUE(looks_bad_completion(" u001cu001cu001c"));                      // the C2 symptom
    CHECK_TRUE(looks_bad_completion(" hahahahahaha"));
    CHECK_TRUE(looks_bad_completion(" <|endoftext|>"));
    CHECK_TRUE(looks_bad_completion("Continuation: foo"));
    CHECK_TRUE(looks_bad_completion(" the the the the the"));                  // word-level repeat

    // Accepted.
    CHECK_FALSE(looks_bad_completion(" going to the store"));
    CHECK_FALSE(looks_bad_completion(" caf\xc3\xa9 tomorrow"));
    CHECK_FALSE(looks_bad_completion(" \xf0\x9f\x91\x8d thanks!"));
    CHECK_FALSE(looks_bad_completion(" a < b, not a tag"));
    CHECK_FALSE(looks_bad_completion(" $1,000,000,000 in new funding"));
    CHECK_FALSE(looks_bad_completion(" hahaha that's funny"));
    CHECK_FALSE(looks_bad_completion(" Mississippi and Tennessee"));
    // F16: real URLs, routes and hex literals are completions, not loops.
    CHECK_FALSE(looks_bad_completion(" https://example.com/en/en/en/index.html"));
    CHECK_FALSE(looks_bad_completion(" http://localhost:8080/api/v1/v1/v1"));
    CHECK_FALSE(looks_bad_completion(" at 0xdeadbeefdeadbeefdeadbeef"));
    CHECK_FALSE(looks_bad_completion(" the a-b-a-b-a-b-a-b pattern"));
    // F17: an invisible is cleaned out of a completion, never a reason to drop it. (The
    // caller strips; the gate's job is only to not veto.)
    CHECK_FALSE(looks_bad_completion(" \xef\xbb\xbfgoing to the store"));
    CHECK_EQ(strip_format_scalars(" \xef\xbb\xbfgoing to the store"), " going to the store");
    CHECK_FALSE(looks_bad_completion(" a\xe2\x80\x8b tricky paste"));
}

// The pre-existing shaping helpers move with the rest of the text layer; keep a
// smoke test so the header cannot silently change their behaviour.
static void test_shaping_unchanged() {
    CHECK_EQ(trim("  hi  "), "hi");
    CHECK_EQ(limit_words("one two three four", 2), "one two");
    CHECK_EQ(strip_html_tags("a <em>b</em> c"), "a b c");
    CHECK_EQ(strip_html_tags("a < b"), "a < b");
    CHECK_EQ(first_line_clean(" <|think|> hello "), "hello");
    CHECK_EQ(remove_echo("the cat sat", "the cat"), "sat");
    CHECK_EQ(utf8_safe("caf\xc3\xa9"), "caf\xc3\xa9");
    CHECK_EQ(utf8_safe("caf\xc3"), "caf");
    CHECK_EQ(stable_tail("one. two three four", 12), "three four");
    CHECK_TRUE(is_orphan_number(" 100%", "the zoom is "));
    CHECK_FALSE(is_orphan_number(" apples", "I have 3 "));
    CHECK_INT(last_nonspace("abc  "), 'c');
}

int main() {
    test_swift_roundtrip();
    test_escapes();
    test_malformed_and_truncated();
    test_truncation_sweep();
    test_key_lookup();
    test_json_escape_roundtrip();
    test_strip_disallowed();
    test_format_scalars();
    test_repeated_run();
    test_output_gate();
    test_shaping_unchanged();

    printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
