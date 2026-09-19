import Foundation

// Standalone assert harness for the store-sanitation layer: TextSanitizer's scalar
// policy, PersonalLexicon's word shape, and StoreMigration end to end against a
// synthetic fixture directory (and, when one is handed to it, a COPY of a real store
// directory — counts only, never contents).
//
// Deliberately NOT in scripts/typer/: that directory is compiled into the app by glob
// (see scripts/build.sh), and a second entry point would break the build.
//
// Usage:  store_tests [scratch-dir] [real-store-copy-dir]
// Run it through scripts/run_store_tests.sh, which compiles and invokes it.
// Just the two text fields of a training row, decoded with JSONDecoder on purpose:
// JSONSerialization treats a leading U+FEFF in a string value as a byte-order mark and
// eats it, so a poisoned field would read back clean and the assertion would pass for the
// wrong reason.
struct RowProbe: Decodable {
    let context: String?
    let suggestion: String?
}

@main
struct StoreTests {

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

    static func scalar(_ v: UInt32) -> Unicode.Scalar { Unicode.Scalar(v)! }

    static func main() {
        let fm = FileManager.default

        // MARK: TextSanitizer — scalar policy

        section("TextSanitizer.isAllowed")

        // The exact payloads the non-text keys used to append to the typed buffer.
        let controlKeys: [(UInt32, String)] = [
            (0x001C, "left arrow"), (0x001D, "right arrow"), (0x001E, "up arrow"), (0x001F, "down arrow"),
            (0x0001, "Home"), (0x0004, "End"), (0x000B, "PageUp"), (0x000C, "PageDown"),
            (0x007F, "forward delete"), (0x0010, "F-key"), (0x0003, "keypad Enter"), (0x001B, "Clear"),
        ]
        for (v, name) in controlKeys {
            check(!TextSanitizer.isAllowed(scalar(v)), "\(name) U+\(String(v, radix: 16)) must be disallowed")
        }

        // Every C0 control except tab / newline / CR.
        for v in UInt32(0x00)...UInt32(0x1F) where v != 0x09 && v != 0x0A && v != 0x0D {
            check(!TextSanitizer.isAllowed(scalar(v)), "C0 U+\(String(v, radix: 16)) disallowed")
        }
        check(TextSanitizer.isAllowed(scalar(0x09)), "tab allowed")
        check(TextSanitizer.isAllowed(scalar(0x0A)), "newline allowed")
        check(TextSanitizer.isAllowed(scalar(0x0D)), "carriage return allowed")

        // C1 controls (and DEL).
        for v in UInt32(0x7F)...UInt32(0x9F) {
            check(!TextSanitizer.isAllowed(scalar(v)), "C1 U+\(String(v, radix: 16)) disallowed")
        }

        // Private use, all three areas.
        for v: UInt32 in [0xE000, 0xF000, 0xF8FF, 0xF0000, 0xF1234, 0xFFFFD, 0x100000, 0x10FFFD] {
            check(!TextSanitizer.isAllowed(scalar(v)), "private use U+\(String(v, radix: 16)) disallowed")
        }

        // Format characters (Cf) — except the zero-width joiner.
        for v: UInt32 in [0x00AD, 0x200B, 0x200E, 0x200F, 0x202A, 0x202E, 0x2060, 0xFEFF, 0x061C] {
            check(!TextSanitizer.isAllowed(scalar(v)), "format U+\(String(v, radix: 16)) disallowed")
        }
        check(TextSanitizer.isAllowed(scalar(0x200D)), "ZWJ allowed (emoji sequences need it)")
        check(TextSanitizer.isAllowed(scalar(0xFE0F)), "VS16 allowed (emoji presentation)")
        // The TAG block is Cf too, and it is what a subdivision flag is made of: 🏴 followed
        // by tag letters and terminated by U+E007F. Disallowing it mangled those flags in the
        // buffer and dropped any completion containing one — while the C++ helper's
        // `is_format_scalar` allowed the same block, so the two halves of one whitelist
        // disagreed. U+E0001 is NOT exempt: it holds nothing together.
        for v: UInt32 in [0xE0020, 0xE0041, 0xE0067, 0xE007F] {
            check(TextSanitizer.isAllowed(scalar(v)),
                  "tag U+\(String(v, radix: 16)) allowed (flag sequences need it)")
            check(!TextSanitizer.isInvisibleFormat(scalar(v)),
                  "tag U+\(String(v, radix: 16)) is not stripped as invisible formatting")
        }
        check(!TextSanitizer.isAllowed(scalar(0xE0001)), "U+E0001 (deprecated language tag) still disallowed")
        check(TextSanitizer.isInvisibleFormat(scalar(0xE0001)), "U+E0001 is still stripped")
        // The England flag, end to end, through every gate.
        let england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        check(TextSanitizer.isClean(england), "the England flag is clean text")
        check(TextSanitizer.strippingInvisibles(england) == england,
              "the England flag survives the invisible strip byte for byte")
        check(TextSanitizer.stripped(england) == england, "…and the last-resort strip too")

        // Replacement character + noncharacters.
        check(!TextSanitizer.isAllowed(scalar(0xFFFD)), "U+FFFD disallowed")
        for v: UInt32 in [0xFDD0, 0xFDE0, 0xFDEF, 0xFFFE, 0xFFFF, 0x1FFFE, 0x1FFFF, 0x10FFFE, 0x10FFFF] {
            check(!TextSanitizer.isAllowed(scalar(v)), "noncharacter U+\(String(v, radix: 16)) disallowed")
        }
        check(TextSanitizer.isAllowed(scalar(0xFDF0)), "U+FDF0 (just past the noncharacter block) allowed")

        section("TextSanitizer.isClean")

        check(TextSanitizer.isClean(""), "empty string is clean")
        check(TextSanitizer.isClean("the quick brown fox"), "plain ASCII clean")
        check(TextSanitizer.isClean("naïve café résumé Ångström"), "accented text clean")
        check(TextSanitizer.isClean("an em dash — and an en dash – and “curly quotes”"), "dashes/quotes clean")
        check(TextSanitizer.isClean("line one\nline two\ttabbed\r\n"), "tab/newline/CR clean")
        check(TextSanitizer.isClean("👨‍👩‍👧"), "ZWJ family emoji clean")
        check(TextSanitizer.isClean("❤️"), "VS16 heart emoji clean")
        check(TextSanitizer.isClean("👍🏽 shipping it"), "skin-tone emoji clean")
        check(TextSanitizer.isClean("日本語のテキスト"), "CJK clean")
        check(!TextSanitizer.isClean("hello\u{001C}world"), "embedded left-arrow control not clean")
        check(!TextSanitizer.isClean("tail\u{007F}"), "trailing forward-delete not clean")
        check(!TextSanitizer.isClean("bad \u{FFFD} decode"), "U+FFFD not clean")
        check(!TextSanitizer.isClean("soft\u{00AD}hyphen"), "soft hyphen not clean")

        section("TextSanitizer.stripped")

        check(TextSanitizer.stripped("hello\u{001C}world") == "helloworld", "stripped removes control")
        check(TextSanitizer.stripped("plain") == "plain", "stripped leaves clean text identical")
        check(TextSanitizer.stripped("👨‍👩‍👧") == "👨‍👩‍👧", "stripped keeps a ZWJ sequence intact")
        check(TextSanitizer.isClean(TextSanitizer.stripped("a\u{0001}b\u{FFFD}c\u{E000}d")),
              "stripped output is clean")

        section("TextSanitizer.strippingInvisibles")

        // The policy split: invisibles come OUT, everything else still gets the row dropped.
        check(TextSanitizer.strippingInvisibles("\u{FEFF}leading bom") == "leading bom",
              "a leading byte-order mark is removed")
        check(TextSanitizer.strippingInvisibles("mid\u{200E}dle") == "middle",
              "a bidi mark inside a word is removed")
        check(TextSanitizer.strippingInvisibles("soft\u{00AD}hyphen") == "softhyphen",
              "a soft hyphen is removed")
        check(TextSanitizer.strippingInvisibles("zero\u{200B}width") == "zerowidth",
              "a zero-width space is removed")
        check(TextSanitizer.strippingInvisibles("\u{202A}bidi\u{202C}") == "bidi",
              "bidi embedding controls are removed")
        check(TextSanitizer.strippingInvisibles("nothing to do") == "nothing to do",
              "clean text is returned unchanged")
        check(TextSanitizer.strippingInvisibles("👨‍👩‍👧") == "👨‍👩‍👧",
              "a ZWJ emoji sequence survives — U+200D is NOT stripped")
        check(TextSanitizer.strippingInvisibles("❤️") == "❤️", "VS16 is not a format character")
        // Stripping invisibles does NOT rescue a control character: that is the point.
        check(!TextSanitizer.isClean(TextSanitizer.strippingInvisibles("bad \u{001C} arrow")),
              "a control character survives the invisible strip and still fails isClean")
        check(TextSanitizer.isClean(TextSanitizer.strippingInvisibles("\u{FEFF}only a bom")),
              "a BOM-only offender becomes clean")
        check(!TextSanitizer.isInvisibleFormat(scalar(0x200D)), "ZWJ is not treated as invisible formatting")
        check(TextSanitizer.isInvisibleFormat(scalar(0xFEFF)), "U+FEFF is invisible formatting")
        check(TextSanitizer.isInvisibleFormat(scalar(0x200E)), "U+200E is invisible formatting")
        check(!TextSanitizer.isInvisibleFormat(scalar(0x001C)), "a control character is not invisible FORMATTING")

        section("TextSanitizer.hasHeldKeyRun")

        check(TextSanitizer.hasHeldKeyRun("wwwww"), "wwwww is a held-key run")
        check(TextSanitizer.hasHeldKeyRun("aaaa"), "aaaa is a held-key run (four is the bar)")
        check(TextSanitizer.hasHeldKeyRun("aaaaaaaa"), "aaaaaaaa is a held-key run")
        check(TextSanitizer.hasHeldKeyRun("sooooo tired"), "an inner run counts")
        check(!TextSanitizer.hasHeldKeyRun("aaa"), "three in a row is not a run")
        check(!TextSanitizer.hasHeldKeyRun("balloon"), "balloon is a real word")
        check(!TextSanitizer.hasHeldKeyRun("committee"), "committee is a real word")
        check(!TextSanitizer.hasHeldKeyRun("bookkeeper"), "bookkeeper is a real word")
        check(!TextSanitizer.hasHeldKeyRun(""), "empty string has no run")

        section("PersonalLexicon.isAcceptableWord")

        check(PersonalLexicon.isAcceptableWord("throughput"), "ordinary word accepted")
        check(PersonalLexicon.isAcceptableWord("don't"), "inner apostrophe accepted")
        check(PersonalLexicon.isAcceptableWord("naïve"), "accented word accepted")
        check(!PersonalLexicon.isAcceptableWord("wwwww"), "held-key run rejected")
        check(!PersonalLexicon.isAcceptableWord("aaaaaaaa"), "held-key run rejected")
        check(!PersonalLexicon.isAcceptableWord("route66"), "digits rejected")
        check(!PersonalLexicon.isAcceptableWord("hel\u{001C}lo"), "control character rejected")
        check(!PersonalLexicon.isAcceptableWord("'quoted"), "leading apostrophe rejected")
        check(!PersonalLexicon.isAcceptableWord("quoted'"), "trailing apostrophe rejected")
        check(!PersonalLexicon.isAcceptableWord(""), "empty rejected")

        // MARK: StoreMigration — synthetic fixture

        section("StoreMigration on a synthetic fixture")

        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
                       ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let scratch = root.appendingPathComponent("store-tests-\(UUID().uuidString)")
        try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let fixture = scratch.appendingPathComponent("fixture")
        try! fm.createDirectory(at: fixture, withIntermediateDirectories: true)

        func write(_ name: String, _ text: String, in dir: URL) {
            let target = dir.appendingPathComponent(name)
            try! Data(text.utf8).write(to: target)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        func read(_ name: String, in dir: URL) -> String {
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }

        // lexicon: three keepers, three artifacts, one rescued by the invisible strip.
        write("lexicon.json", """
        {"throughput":12,"kubernetes":7,"don't":5,"wwwww":9,"aaaaaaaa":4,"hel\\u001clo":3,"caf\\u200ee":6}
        """, in: fixture)

        // style: three clean lines, two carrying a control character, one carrying only a
        // byte-order mark (kept, with the mark removed).
        write("style.txt", """

        chat\tthis is a perfectly ordinary sentence
        email\tanother sentence that should survive the pass
        chat\tthis one has a stray \u{001C} arrow in it
        docs\tem dashes — and accents café stay put
        other\ttrailing forward delete sneaks in\u{007F}
        chat\t\u{FEFF}a line whose only sin is a byte-order mark
        """, in: fixture)

        // topics: two clean, two poisoned (one via a key, one via the note), one carrying
        // only invisibles (kept, stripped).
        write("topics.json", """
        [{"at":1.0,"app":"Safari","title":"Headphones","keys":["headphones","sony"],"note":"Sony headphones review"},
         {"at":2.0,"app":"Safari","title":"Bad","keys":["ok\\u001cbad"],"note":"fine note"},
         {"at":3.0,"app":"Mail","title":"Mortgage","keys":["mortgage"],"note":"note with \\ufffd in it"},
         {"at":4.0,"app":"Notes","title":"Clean","keys":["espresso"],"note":"café notes — fine"},
         {"at":5.0,"app":"Notes","title":"Bom","keys":["\\ufeffmortgage"],"note":"\\ufeffa note with only a mark"}]
        """, in: fixture)

        // training: three clean rows, two poisoned, one unparseable.
        let trainingLines = [
            #"{"schema_version":2,"ts":1.0,"context":"the quick brown","suggestion":" fox jumps","accepted":true}"#,
            #"{"schema_version":2,"ts":2.0,"context":"bad \u001c context","suggestion":" nope","accepted":false}"#,
            #"{"schema_version":2,"ts":3.0,"context":"clean context here","suggestion":" and clean too","accepted":true}"#,
            #"{"schema_version":2,"ts":4.0,"context":"fine","suggestion":" bad \u007f end","accepted":false}"#,
            "not json at all",
            #"{"schema_version":2,"ts":5.0,"context":"emoji ❤️ 👨‍👩‍👧 survive","suggestion":" indeed","accepted":true}"#,
            // A literal U+FEFF in FIRST position: JSONSerialization silently eats it and
            // reports the field clean, JSONDecoder does not. This row is the regression
            // guard for that — real capture data was full of them (897 of 14,503 rows).
            // Under the strip-first policy it is now KEPT, rewritten without the mark:
            // throwing away 6% of the corpus over a character with no visual extent was a
            // worse outcome than the mark itself.
            "{\"schema_version\":2,\"ts\":6.0,\"context\":\"\u{FEFF}leading byte-order mark\",\"suggestion\":\" bom\",\"accepted\":false}",
        ]
        write("training.jsonl", trainingLines.joined(separator: "\n") + "\n", in: fixture)

        write("feedback.json", #"{"outcomes":[false,false,true],"acceptWords":[2]}"#, in: fixture)
        write("router.json",
              #"{"shareA":0.2,"rewardsA":[0.02],"rewardsB":[0.02],"sinceLastAdjust":9,"locked":null}"#,
              in: fixture)

        let storeNames = ["lexicon.json", "style.txt", "topics.json", "training.jsonl",
                          "feedback.json", "router.json"]
        var originals: [String: Data] = [:]
        for name in storeNames { originals[name] = try! Data(contentsOf: fixture.appendingPathComponent(name)) }

        let suite = "typer.store-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var logLines: [String] = []
        StoreMigration.runIfNeeded(directory: fixture, defaults: defaults) { logLines.append($0) }

        check(defaults.integer(forKey: StoreMigration.versionKey) == StoreMigration.targetVersion,
              "migration stamps the version once every store succeeded")
        check(logLines.count == 6, "one summary line per store (got \(logLines.count))")
        for line in logLines { print("   " + line) }

        // Backups: present, byte-identical, 0600.
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyyMMdd"
        let stamp = stampFormatter.string(from: Date())
        for name in storeNames {
            let backup = fixture.appendingPathComponent("\(name).pre-sanitize-\(stamp).bak")
            check(fm.fileExists(atPath: backup.path), "backup exists for \(name)")
            check((try? Data(contentsOf: backup)) == originals[name], "backup of \(name) is byte-identical")
            let mode = (try? fm.attributesOfItem(atPath: backup.path))?[.posixPermissions] as? Int
            check(mode == 0o600, "backup of \(name) is 0600 (got \(mode.map { String($0, radix: 8) } ?? "nil"))")
        }

        // lexicon: artifacts gone, keepers intact with their counts, invisibles stripped.
        let lexicon = (try? Data(contentsOf: fixture.appendingPathComponent("lexicon.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] } ?? [:]
        check(lexicon.count == 4, "lexicon keeps 4 entries (got \(lexicon.count))")
        check(lexicon["throughput"] == 12, "lexicon keeps throughput with its count")
        check(lexicon["kubernetes"] == 7, "lexicon keeps kubernetes")
        check(lexicon["don't"] == 5, "lexicon keeps don't")
        check(lexicon["cafe"] == 6, "lexicon keeps a word whose only problem was a bidi mark, stripped")
        check(lexicon["wwwww"] == nil, "lexicon drops wwwww")
        check(lexicon["aaaaaaaa"] == nil, "lexicon drops aaaaaaaa")
        check(!lexicon.keys.contains { !TextSanitizer.isClean($0) }, "no unclean lexicon keys left")

        // style: polluted lines gone, clean ones intact, BOM-only line kept without its BOM.
        let style = read("style.txt", in: fixture)
        check(TextSanitizer.isClean(style), "style.txt is clean after the migration")
        check(style.contains("this is a perfectly ordinary sentence"), "style keeps the first clean line")
        check(style.contains("em dashes — and accents café stay put"), "style keeps the em-dash/accent line")
        check(!style.contains("stray"), "style drops the arrow line")
        check(!style.contains("forward delete"), "style drops the forward-delete line")
        check(style.contains("a line whose only sin is a byte-order mark"),
              "style KEEPS a line whose only offender was a byte-order mark")
        check(!style.unicodeScalars.contains { $0.value == 0xFEFF }, "…with the mark itself removed")
        check(style.split(separator: "\n").count == 4, "style keeps exactly 4 sample lines")

        // topics: poisoned entries gone, whichever half was poisoned; invisibles stripped.
        let topics = (try? Data(contentsOf: fixture.appendingPathComponent("topics.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        check(topics.count == 3, "topics keeps 3 entries (got \(topics.count))")
        check(topics.contains { ($0["title"] as? String) == "Headphones" }, "topics keeps the headphones entry")
        check(topics.contains { ($0["title"] as? String) == "Clean" }, "topics keeps the café entry")
        check(!topics.contains { ($0["title"] as? String) == "Bad" }, "topics drops the bad-key entry")
        check(!topics.contains { ($0["title"] as? String) == "Mortgage" }, "topics drops the U+FFFD-note entry")
        let bom = topics.first { ($0["title"] as? String) == "Bom" }
        check(bom != nil, "topics KEEPS the entry whose only offender was a byte-order mark")
        check((bom?["note"] as? String) == "a note with only a mark", "…with the note's mark removed")
        check((bom?["keys"] as? [String]) == ["mortgage"], "…and the key's mark removed")

        // training: poisoned rows gone, clean rows byte-identical, unparseable line dropped,
        // invisible-only rows kept and rewritten.
        let training = read("training.jsonl", in: fixture).split(separator: "\n").map(String.init)
        check(training.count == 4, "training keeps 4 rows (got \(training.count))")
        check(training.contains(trainingLines[0]), "training keeps row 0 byte-identical")
        check(training.contains(trainingLines[2]), "training keeps row 2 byte-identical")
        check(training.contains(trainingLines[5]), "training keeps the emoji row byte-identical")
        check(!training.contains { $0.contains("nope") }, #"training drops the \u001c-context row"#)
        check(!training.contains { $0.contains("bad \\u007f end") }, #"training drops the \u007f-suggestion row"#)
        check(!training.contains("not json at all"), "training drops the unparseable line")
        check(training.contains { $0.contains("leading byte-order mark") },
              "training KEEPS a row whose context merely STARTS with U+FEFF")
        // …and rewritten with the mark actually gone. Checked through JSONDecoder, which
        // (unlike JSONSerialization) does not silently swallow a leading U+FEFF.
        check(training.allSatisfy { row in
                  guard let probe = try? JSONDecoder().decode(RowProbe.self, from: Data(row.utf8)) else { return false }
                  return TextSanitizer.isClean(probe.context ?? "") && TextSanitizer.isClean(probe.suggestion ?? "")
              }, "every surviving training row decodes to clean text")
        check(!read("training.jsonl", in: fixture).unicodeScalars.contains { !TextSanitizer.isAllowed($0) },
              "training.jsonl holds no disallowed scalar afterwards, escaped or literal")

        // feedback/router: reset to their initial state.
        check(!fm.fileExists(atPath: fixture.appendingPathComponent("feedback.json").path),
              "feedback.json reset (removed — its loader treats missing as no history)")
        check(!fm.fileExists(atPath: fixture.appendingPathComponent("router.json").path),
              "router.json reset (removed — its loader treats missing as 50/50 unlocked)")

        // Permissions survive the rewrite, and no temp files are left behind.
        for name in ["lexicon.json", "style.txt", "topics.json", "training.jsonl"] {
            let mode = (try? fm.attributesOfItem(atPath: fixture.appendingPathComponent(name).path))?[.posixPermissions] as? Int
            check(mode == 0o600, "\(name) is still 0600 after the rewrite")
        }
        let leftovers = (try? fm.contentsOfDirectory(atPath: fixture.path))?.filter { $0.hasSuffix(".tmp") } ?? []
        check(leftovers.isEmpty, "no .tmp files left behind (found \(leftovers))")

        section("StoreMigration is idempotent")

        let afterFirst = (try? fm.contentsOfDirectory(atPath: fixture.path))?.sorted() ?? []
        var secondRunLog: [String] = []
        StoreMigration.runIfNeeded(directory: fixture, defaults: defaults) { secondRunLog.append($0) }
        let afterSecond = (try? fm.contentsOfDirectory(atPath: fixture.path))?.sorted() ?? []
        check(secondRunLog.isEmpty, "second run logs nothing")
        check(afterFirst == afterSecond, "second run makes no new backups or files")
        check(read("style.txt", in: fixture) == style, "second run leaves style.txt untouched")

        section("StoreMigration leaves an already-clean store alone")

        // A store that needs no edits must not be rewritten and — the point of this — must
        // not be backed up either. A run that fails partway is retried on the next launch,
        // and without this every retry piled up another "-2", "-3" copy of files it had
        // already found clean.
        let cleanDir = scratch.appendingPathComponent("clean")
        try! fm.createDirectory(at: cleanDir, withIntermediateDirectories: true)
        write("lexicon.json", #"{"throughput":12,"kubernetes":7}"#, in: cleanDir)
        write("style.txt", "\nchat\tthis is a perfectly ordinary sentence", in: cleanDir)
        write("topics.json",
              #"[{"at":1.0,"app":"Safari","title":"H","keys":["headphones"],"note":"a fine note"}]"#,
              in: cleanDir)
        write("training.jsonl",
              #"{"schema_version":3,"ts":1.0,"context":"the quick brown","suggestion":" fox","accepted":true}"# + "\n",
              in: cleanDir)
        var cleanOriginals: [String: Data] = [:]
        for name in ["lexicon.json", "style.txt", "topics.json", "training.jsonl"] {
            cleanOriginals[name] = try! Data(contentsOf: cleanDir.appendingPathComponent(name))
        }
        let cleanSuite = "typer.store-tests.\(UUID().uuidString)"
        let cleanDefaults = UserDefaults(suiteName: cleanSuite)!
        defer { cleanDefaults.removePersistentDomain(forName: cleanSuite) }
        var cleanLog: [String] = []
        StoreMigration.runIfNeeded(directory: cleanDir, defaults: cleanDefaults) { cleanLog.append($0) }
        for line in cleanLog { print("   " + line) }
        check(cleanDefaults.integer(forKey: StoreMigration.versionKey) == StoreMigration.targetVersion,
              "an already-clean directory still counts as migrated")
        check(cleanLog.allSatisfy { $0.contains("already clean") },
              "every clean store reports itself as already clean")
        for name in ["lexicon.json", "style.txt", "topics.json", "training.jsonl"] {
            check((try? Data(contentsOf: cleanDir.appendingPathComponent(name))) == cleanOriginals[name],
                  "\(name) is byte-identical after a no-op pass")
        }
        let cleanBackups = ((try? fm.contentsOfDirectory(atPath: cleanDir.path)) ?? []).filter { $0.contains(".bak") }
        check(cleanBackups.isEmpty, "no backups are made for stores that needed no edits (found \(cleanBackups))")

        section("StoreMigration on missing and empty stores")

        let emptyDir = scratch.appendingPathComponent("empty")
        try! fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let emptySuite = "typer.store-tests.\(UUID().uuidString)"
        let emptyDefaults = UserDefaults(suiteName: emptySuite)!
        defer { emptyDefaults.removePersistentDomain(forName: emptySuite) }
        var emptyLog: [String] = []
        StoreMigration.runIfNeeded(directory: emptyDir, defaults: emptyDefaults) { emptyLog.append($0) }
        check(emptyLog.isEmpty, "missing files produce no log lines")
        check(emptyDefaults.integer(forKey: StoreMigration.versionKey) == StoreMigration.targetVersion,
              "a directory with no stores still counts as migrated")
        check(((try? fm.contentsOfDirectory(atPath: emptyDir.path)) ?? []).isEmpty,
              "nothing is created in a store-less directory")

        let zeroDir = scratch.appendingPathComponent("zero")
        try! fm.createDirectory(at: zeroDir, withIntermediateDirectories: true)
        for name in ["lexicon.json", "style.txt", "topics.json", "training.jsonl"] { write(name, "", in: zeroDir) }
        let zeroSuite = "typer.store-tests.\(UUID().uuidString)"
        let zeroDefaults = UserDefaults(suiteName: zeroSuite)!
        defer { zeroDefaults.removePersistentDomain(forName: zeroSuite) }
        var zeroLog: [String] = []
        StoreMigration.runIfNeeded(directory: zeroDir, defaults: zeroDefaults) { zeroLog.append($0) }
        check(zeroLog.count == 4, "each empty store logs once (got \(zeroLog.count))")
        check(zeroDefaults.integer(forKey: StoreMigration.versionKey) == StoreMigration.targetVersion,
              "empty stores still mark the migration done")
        for name in ["lexicon.json", "style.txt", "topics.json", "training.jsonl"] {
            check((try? Data(contentsOf: zeroDir.appendingPathComponent(name)))?.isEmpty ?? false,
                  "\(name) stays empty")
        }

        // MARK: TrainingLog — write gate + streaming roll

        section("TrainingLog write gate and rolling")

        func makeRecord(context: String, suggestion: String, ts: Double = 0) -> TrainingLog.Record {
            TrainingLog.Record(schema_version: 2, ts: ts, context: context, suggestion: suggestion,
                               accepted: false, accept_kind: "none", words_accepted: 0, words_shown: 3,
                               confidence: 0.5, shown: true, exploration: false, min_conf: 0.4,
                               max_words: 6, app_category: "docs", source: "generate",
                               model: "test.gguf", reason: "resolved")
        }

        let logDir = scratch.appendingPathComponent("traininglog")
        try! fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("training.jsonl")

        let gateLog = TrainingLog(directory: logDir)
        gateLog.record(makeRecord(context: "a clean context", suggestion: " and suggestion", ts: 1))
        gateLog.record(makeRecord(context: "control \u{001C} context", suggestion: " fine", ts: 2))
        gateLog.record(makeRecord(context: "fine", suggestion: " control \u{007F} suggestion", ts: 3))
        gateLog.record(makeRecord(context: "\u{FEFF}leading bom", suggestion: " fine", ts: 4))
        gateLog.record(makeRecord(context: "emoji ❤️ 👨‍👩‍👧", suggestion: " ok", ts: 5))
        gateLog.flush()

        let written = (try? String(contentsOf: logFile, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        check(written.count == 3, "TrainingLog keeps the 3 usable rows (got \(written.count))")
        check(gateLog.count() == 3, "TrainingLog.count() matches what was written")
        check(!written.contains { $0.contains("001c") || $0.contains("001C") },
              "TrainingLog rejects a control character in context")
        check(!written.contains { $0.contains("007f") || $0.contains("007F") },
              "TrainingLog rejects a control character in the suggestion")
        check(written.contains { $0.contains("leading bom") },
              "TrainingLog KEEPS a row whose only offender was a byte-order mark")
        check(!written.contains { $0.contains("feff") || $0.contains("FEFF") },
              "…with the mark stripped out before the row was written")
        check(written.allSatisfy { $0.contains("\"schema_version\":\(TrainingLog.schemaVersion)") },
              "TrainingLog stamps the current schema version on every row")
        let gateMode = (try? fm.attributesOfItem(atPath: logFile.path))?[.posixPermissions] as? Int
        check(gateMode == 0o600, "TrainingLog creates the file 0600")

        // Rolling: hand it a file already past the 8 MB cap, then append one row. The roll
        // must keep the newest half and nothing else — checked by the sequence numbers
        // baked into each pre-seeded line.
        let filler = (0..<40_000).map { i in
            #"{"schema_version":3,"ts":\#(i).0,"context":"row \#(i) padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding","suggestion":" s","accepted":true}"#
        }
        try! Data((filler.joined(separator: "\n") + "\n").utf8).write(to: logFile)
        let seededSize = (try? fm.attributesOfItem(atPath: logFile.path))?[.size] as? Int ?? 0
        check(seededSize > 8_000_000, "the seeded log is past the 8 MB cap (got \(seededSize) bytes)")

        let rollLog = TrainingLog(directory: logDir)
        rollLog.record(makeRecord(context: "the row that triggers the roll", suggestion: " tail", ts: 99))
        rollLog.flush()

        let rolled = (try? String(contentsOf: logFile, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        let expectedKept = (filler.count + 1) / 2
        check(rolled.count == expectedKept, "roll keeps half the rows (\(rolled.count) vs \(expectedKept))")
        check(rolled.last?.contains("the row that triggers the roll") == true, "roll keeps the newest row last")
        check(rolled.first == filler[filler.count + 1 - expectedKept],
              "roll cuts on a line boundary, at the right line")
        check(!rolled.contains(filler[0]), "roll drops the oldest row")
        check(rolled.contains(filler[filler.count - 1]), "roll keeps the last seeded row")
        check(rollLog.count() == expectedKept, "count() is corrected after the roll")
        let rolledSize = (try? fm.attributesOfItem(atPath: logFile.path))?[.size] as? Int ?? 0
        // Half the *rows*, so a little over half the bytes (later rows carry larger indices).
        check(rolledSize > seededSize / 3 && rolledSize < seededSize * 3 / 5,
              "rolled file is about half the size (\(rolledSize) of \(seededSize))")
        let rolledMode = (try? fm.attributesOfItem(atPath: logFile.path))?[.posixPermissions] as? Int
        check(rolledMode == 0o600, "rolled file is still 0600")
        let rollLeftovers = (try? fm.contentsOfDirectory(atPath: logDir.path))?.filter { $0.hasSuffix(".tmp") } ?? []
        check(rollLeftovers.isEmpty, "roll leaves no .tmp file behind (found \(rollLeftovers))")

        // MARK: Optional — a COPY of a real store directory (counts only, never contents)

        if CommandLine.arguments.count > 2 {
            section("StoreMigration on a copy of a real store directory (counts only)")
            let realCopy = URL(fileURLWithPath: CommandLine.arguments[2])
            let realSuite = "typer.store-tests.\(UUID().uuidString)"
            let realDefaults = UserDefaults(suiteName: realSuite)!
            defer { realDefaults.removePersistentDomain(forName: realSuite) }
            var realLog: [String] = []
            StoreMigration.runIfNeeded(directory: realCopy, defaults: realDefaults) { realLog.append($0) }
            for line in realLog { print("   " + line) }
            check(realDefaults.integer(forKey: StoreMigration.versionKey) == StoreMigration.targetVersion,
                  "real-data copy migrated cleanly")
            check(TextSanitizer.isClean(read("style.txt", in: realCopy)), "real style.txt is clean afterwards")
            let realLexicon = (try? Data(contentsOf: realCopy.appendingPathComponent("lexicon.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] } ?? [:]
            check(!realLexicon.keys.contains { !PersonalLexicon.isAcceptableWord($0) },
                  "real lexicon has no unacceptable keys left")
            var badTraining = 0
            if let handle = try? FileHandle(forReadingFrom: realCopy.appendingPathComponent("training.jsonl")) {
                defer { try? handle.close() }
                var pending = Data()
                func inspect(_ line: Data) {
                    guard !line.isEmpty,
                          let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                    let ctx = row["context"] as? String ?? ""
                    let sug = row["suggestion"] as? String ?? ""
                    if !TextSanitizer.isClean(ctx) || !TextSanitizer.isClean(sug) { badTraining += 1 }
                }
                while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: 0x0A) {
                        inspect(Data(pending[pending.startIndex..<nl]))
                        pending = Data(pending[pending.index(after: nl)...])
                    }
                }
                inspect(pending)
            }
            check(badTraining == 0, "real training.jsonl has no polluted rows left (found \(badTraining))")
        }

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) FAILURES\n".utf8))
            exit(1)
        }
    }
}
