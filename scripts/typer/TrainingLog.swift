import Foundation

// Opt-in, on-device corpus of (context → shown suggestion, accepted?) examples,
// captured straight from the live completion loop. This is the seed dataset for a
// future local autocomplete model AND its accept/reject reward signal.
//
// OFF by default. Stored at ~/Library/Application Support/typer/training.jsonl, 0600,
// and wiped by "Reset All Data". One self-contained JSON object per line (JSONL).
//
// PRIVACY. `context` is ONLY the immediate before-cursor text the user typed — never
// the folded-in window/clipboard/OCR background blocks. Even so, typed text can hold
// secrets (a password in a non-secure field, a 2FA code, an API key), so before a row
// is written the context and suggestion are screened by `looksSensitive` and the whole
// example is DROPPED if anything secret-shaped appears (emails, URLs, long digit runs,
// key-like tokens, file paths). Capture is also skipped during macOS secure input, in
// disabled apps, and in known credential apps (`sensitiveAppBundles`). Nothing here
// ever leaves the machine. This corrects the earlier "same sensitivity as style.txt"
// framing — the raw buffer is strictly more sensitive, so it is filtered, not trusted.
final class TrainingLog {
    // Bumped 2 → 3 when the control-character gate landed: every v3 row is guaranteed to
    // have a `context` and `suggestion` that pass TextSanitizer, so a trainer can take
    // v3 rows at face value and knows v2 rows still need screening.
    static let schemaVersion = 3

    struct Record: Codable {
        var schema_version: Int   // stamped to TrainingLog.schemaVersion on write
        let ts: Double            // unix seconds when the suggestion resolved
        var context: String       // immediate before-cursor text (screened, no secrets)
        var suggestion: String     // the full suggestion that was shown
        let accepted: Bool         // at least one word taken
        let accept_kind: String    // "tab" | "backtick" | "typethrough" | "none"
        let words_accepted: Int    // words taken
        let words_shown: Int       // words in the full suggestion
        let confidence: Double     // mean token probability the model reported
        let shown: Bool            // false for exploration/suppressed (never displayed)
        let exploration: Bool      // logged below the confidence gate (suppressed region)
        let min_conf: Double       // effective confidence gate at the time
        let max_words: Int         // words requested for this generation
        let app_category: String   // chat / email / docs / code / browser / other
        let source: String         // "generate" | "prefetch"
        let model: String          // gguf filename — the policy/version this came from
        let reason: String         // "resolved" | "dismissed" | "suppressed"
    }

    // Credential / secret-manager apps where suggestions must never be captured at all,
    // independent of macOS secure-input (which only covers OS-designated fields).
    static let sensitiveAppBundles: Set<String> = [
        "com.1password.1password", "com.1password.1password-launcher", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal", "com.callpod.keepermac",
        "com.lastpass.lastpassmacdesktop", "com.apple.keychainaccess", "com.apple.Passwords",
    ]

    // True if `s` contains anything secret-shaped. Conservative on purpose: a few
    // false positives (dropping a sentence that mentions a year or a long word) is a
    // fine price for never persisting a credential. Mirrors PersonalLexicon's intent
    // of refusing digits/URLs/emails/paths.
    static func looksSensitive(_ s: String) -> Bool {
        if s.isEmpty { return false }
        let patterns = [
            "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",  // email
            "https?://|www\\.",                                  // url
            "[0-9]{4,}",                                         // 4+ digit run (codes, cards, ids)
            "(?:[0-9][ -]){6,}[0-9]",                            // spaced/hyphenated number (phone/card)
            "[A-Za-z0-9+/=_-]{20,}",                             // long token (keys, hashes, jwts)
            "(?:/[A-Za-z0-9._~-]+){2,}",                         // filesystem path
        ]
        for p in patterns where s.range(of: p, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private let url: URL
    private let queue = DispatchQueue(label: "typer.training", qos: .utility)
    private let encoder = JSONEncoder()
    private let maxBytes = 8_000_000      // ~8 MB rolling cap (keeps the recent half)
    private let lock = NSLock()
    private var countCache = -1           // lazily counted; -1 = unknown

    // `directory` defaults to the real store location; it is a parameter so the rolling
    // logic can be exercised against a throwaway file instead of the user's corpus.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("training.jsonl")
    }

    func record(_ r: Record) {
        // A row whose context or suggestion carries a control character (a stray arrow
        // key that landed in the buffer), a private-use glyph or a U+FFFD is training
        // poison — the model would learn to emit it. Drop the row rather than strip it:
        // a context with VISIBLE characters silently removed no longer matches the
        // suggestion it is paired with, which is a worse example than none.
        var row = r
        // Invisible formatting is a different case from a control character: it arrives
        // from an app's AX text rather than from a key, it carries no information, and it
        // sits inside otherwise perfectly good prose. Strip it, THEN judge what is left —
        // on a real capture directory, 897 of 14,503 rows contained nothing disallowed
        // except invisibles, and the drop-the-row rule was discarding all of them.
        row.context = TextSanitizer.strippingInvisibles(r.context)
        row.suggestion = TextSanitizer.strippingInvisibles(r.suggestion)
        guard TextSanitizer.isClean(row.context), TextSanitizer.isClean(row.suggestion) else { return }
        row.schema_version = Self.schemaVersion
        guard let line = try? encoder.encode(row) else { return }
        lock.lock(); if countCache >= 0 { countCache += 1 }; lock.unlock()
        queue.async { self.append(line) }
    }

    private func append(_ jsonLine: Data) {
        var data = jsonLine
        data.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        }
        // Roll the file when it grows past the cap: keep the most recent half.
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > maxBytes { roll() }
    }

    // Drop the older half of the log, streaming. The file is at the 8 MB cap by the time
    // this runs, and the old implementation read all of it into a String (plus a second
    // copy for the split and a third for the join) — ~32 MB of peak RAM on a machine that
    // does not have it to spare. Two chunked passes instead: one to count lines, one to
    // copy the tail into a sibling temp file that atomically replaces the original.
    private func roll() {
        let fm = FileManager.default
        guard let total = countLines(in: url), total > 1 else { return }
        let keep = total / 2
        let skip = total - keep
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".training-roll-\(UUID().uuidString).tmp")
        guard copyLines(from: url, to: tmp, skipping: skip) else {
            try? fm.removeItem(at: tmp)
            return
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        guard (try? fm.replaceItemAt(url, withItemAt: tmp)) != nil else {
            try? fm.removeItem(at: tmp)
            return
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lock.lock(); countCache = keep; lock.unlock()
    }

    // Number of records in the file, counted a chunk at a time. A trailing fragment with
    // no final newline still counts as a line, matching how the rows are read back.
    private func countLines(in file: URL) -> Int? {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? fh.close() }
        var lines = 0
        var lastByte: UInt8?
        // `try?` here would make a mid-file read error indistinguishable from EOF, and the
        // undercount would then make `roll()` drop far more of the corpus than half. nil
        // means "don't roll", which is always safe.
        while true {
            let chunk: Data?
            do { chunk = try fh.read(upToCount: Self.chunkBytes) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            for b in chunk where b == 0x0A { lines += 1 }
            lastByte = chunk.last
        }
        guard let last = lastByte else { return 0 }
        return last == 0x0A ? lines : lines + 1
    }

    // Copy `src` to `dst` starting just past the `skip`-th newline, a chunk at a time.
    private func copyLines(from src: URL, to dst: URL, skipping skip: Int) -> Bool {
        let fm = FileManager.default
        guard fm.createFile(atPath: dst.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let input = try? FileHandle(forReadingFrom: src),
              let output = try? FileHandle(forWritingTo: dst) else { return false }
        defer { try? input.close(); try? output.close() }
        var skipped = 0
        var copying = skip == 0
        var endedWithNewline = true
        // A read error must abort the copy (returning false leaves the original in place),
        // never masquerade as EOF and commit a truncated log over the real one.
        while true {
            let read: Data?
            do { read = try input.read(upToCount: Self.chunkBytes) } catch { return false }
            guard let chunk = read, !chunk.isEmpty else { break }
            var slice = chunk[chunk.startIndex...]
            if !copying {
                // Walk this chunk's newlines until the cut point falls inside it.
                var i = slice.startIndex
                while i < slice.endIndex {
                    if slice[i] == 0x0A {
                        skipped += 1
                        if skipped == skip { copying = true; i = slice.index(after: i); break }
                    }
                    i = slice.index(after: i)
                }
                guard copying else { continue }
                slice = slice[i...]
            }
            guard !slice.isEmpty else { continue }
            endedWithNewline = slice.last == 0x0A
            do { try output.write(contentsOf: Data(slice)) } catch { return false }
        }
        if !endedWithNewline { try? output.write(contentsOf: Data([0x0A])) }
        return true
    }

    private static let chunkBytes = 1 << 16

    // Number of examples recorded (for the menu). Cached; recomputed by scanning the
    // file only the first time after launch or a roll.
    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        if countCache >= 0 { return countCache }
        guard let data = try? Data(contentsOf: url) else { countCache = 0; return 0 }
        countCache = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return countCache
    }

    func clear() {
        lock.lock(); countCache = 0; lock.unlock()
        queue.async { try? FileManager.default.removeItem(at: self.url) }
    }

    // Block until all queued appends have been written — called on app terminate so
    // the tail of capture isn't lost to a fire-and-forget queue on quit.
    func flush() { queue.sync {} }
}

// The context-side of a shown suggestion, held from the moment it is presented until
// it resolves (accepted or rejected), at which point a TrainingLog.Record is written.
struct PendingTrainingExample {
    let context: String
    let suggestion: String
    let conf: Double
    let minConf: Double
    let maxWords: Int
    let category: String
    let source: String
    let model: String
}
