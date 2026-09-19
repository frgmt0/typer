import Foundation

// One-shot repair of the learning stores written before TextSanitizer existed.
//
// Every non-text key (arrows, Home/End, PgUp/PgDn, forward-delete, F-keys) used to be
// appended to the typed buffer as a control character, so the stores accumulated:
//   • style.txt lines with an embedded U+001C–U+001F
//   • training.jsonl rows whose `context` is full of escape codes
//   • lexicon.json entries like "wwwww" from a key held down
// The write paths now reject all of that, but the damage on disk is already done and the
// read paths only *hide* it — the files keep getting sampled, re-encoded and grown. This
// rewrites them once, on the launch after the fix ships.
//
// feedback.json and router.json hold no text but are semantically poisoned: while a
// suggestion was on screen, every arrow-key press was recorded as an explicit rejection.
// That dragged the measured acceptance rate down to ~0.12, which raised the confidence
// gate and clamped suggestions to three words, and left both router arms sitting at a
// ~0.02 mean reward. There is no way to tell a real rejection from a cursor move after
// the fact, so both files are backed up and reset to their initial state; they re-learn
// within a few hundred suggestions.
//
// Safety shape: back up first (never overwriting an existing backup), rewrite atomically
// via a sibling temp file, preserve 0600, and only stamp the version once EVERY store
// succeeded — a partial run is retried on the next launch rather than silently skipped.
enum StoreMigration {

    // UserDefaults gate. Bump `targetVersion` (and add a case below) if a future round
    // of sanitation has to re-walk the stores.
    static let versionKey = "storeSanitizationVersion"
    static let targetVersion = 1

    // What one store's pass produced. `unchanged` is separate from `done` on purpose: a
    // store that needed no edits is never backed up and never rewritten, so a run that
    // fails partway and is retried on the next launch does not pile up a second and third
    // backup of files it already found clean.
    private enum Outcome {
        case unchanged(String)
        case done(String)
        case failed
    }

    // A store's pass asks for the backup itself, immediately before it writes, and aborts
    // if it cannot get one. Returns false when the backup could not be made.
    private typealias BackupRequest = () -> Bool

    static func runIfNeeded(directory: URL, defaults: UserDefaults = .standard, log: (String) -> Void) {
        guard defaults.integer(forKey: versionKey) < targetVersion else { return }

        let stores: [(name: String, sanitize: (URL, BackupRequest) -> Outcome)] = [
            ("lexicon.json", sanitizeLexicon),
            ("style.txt", sanitizeStyle),
            ("topics.json", sanitizeTopics),
            ("training.jsonl", sanitizeTraining),
            ("feedback.json", resetStore),
            ("router.json", resetStore),
        ]

        var allSucceeded = true
        for store in stores {
            let file = directory.appendingPathComponent(store.name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            // The backup is taken lazily, by the pass, right before it writes: no backup,
            // no rewrite — and the version stays unstamped, so the next launch tries again.
            var backupName: String?
            var backupFailed = false
            let backup: BackupRequest = {
                if let existing = backupName { _ = existing; return true }
                guard let made = makeBackup(of: file) else { backupFailed = true; return false }
                backupName = made.lastPathComponent
                return true
            }
            switch store.sanitize(file, backup) {
            case .unchanged(let summary):
                log(summary)
            case .done(let summary):
                log(summary)
            case .failed:
                if backupFailed {
                    log("store-sanitize \(store.name): backup failed, left untouched")
                } else if let backupName {
                    log("store-sanitize \(store.name): rewrite failed, original preserved as \(backupName)")
                } else {
                    log("store-sanitize \(store.name): read failed, left untouched")
                }
                allSucceeded = false
            }
        }

        if allSucceeded {
            defaults.set(targetVersion, forKey: versionKey)
        } else {
            log("store-sanitize incomplete — will retry on next launch")
        }
    }

    // MARK: - Per-store rewrites

    // IMPORTANT, and the reason JSONDecoder shows up below next to JSONSerialization:
    // JSONSerialization silently swallows a U+FEFF sitting at the *start* of a string
    // value (it treats it as a byte-order mark), so a poisoned field reads back clean and
    // the row survives. JSONDecoder keeps it. Real capture data hit exactly this — 836 of
    // 897 BOM-bearing training rows had it in first position — so every check that
    // decides whether text is clean goes through JSONDecoder, and JSONSerialization is
    // used only where the job is to carry an object through unchanged.

    // THE POLICY, applied by every rewrite below: strip invisible formatting FIRST, then
    // drop only what is still unclean.
    //
    // The two classes of offender are not the same problem. A control character in a
    // stored context means a stray arrow key was appended to the typed buffer, so the
    // text genuinely is corrupt and the row is worthless. An invisible format character
    // (U+FEFF, U+200E and the rest of Cf) came in from an application's AX text; it has no
    // visual extent, no linguistic content, and the sentence around it is perfectly good.
    // Measured on a real capture directory, 897 of 14,503 training rows and 17 style lines
    // contained NOTHING disallowed except invisibles — a drop-only rule would have thrown
    // away 6% of the corpus to delete characters nobody can see.

    // lexicon.json is `{"word": count}`. Keep only entries whose key is a real word after
    // invisibles come out: letters plus inner apostrophes, no control characters, no
    // held-key run. Two keys that collapse to the same word have their counts merged.
    private static func sanitizeLexicon(_ file: URL, backup: BackupRequest) -> Outcome {
        guard let data = try? Data(contentsOf: file) else { return .failed }
        guard !data.isEmpty else { return .unchanged("store-sanitize lexicon.json: empty, nothing to do") }
        guard let counts = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return .unchanged("store-sanitize lexicon.json: unreadable, left as-is")
        }
        var kept: [String: Int] = [:]
        var dropped = 0, stripped = 0
        for (word, count) in counts {
            let cleaned = TextSanitizer.strippingInvisibles(word)
            guard PersonalLexicon.isAcceptableWord(cleaned) else { dropped += 1; continue }
            if cleaned != word { stripped += 1 }
            kept[cleaned, default: 0] += count
        }
        guard dropped > 0 || stripped > 0 else {
            return .unchanged("store-sanitize lexicon.json: already clean (\(kept.count) entries)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let out = try? encoder.encode(kept), backup(), writeAtomically(out, to: file) else { return .failed }
        return .done("store-sanitize lexicon.json: kept \(kept.count), dropped \(dropped), stripped \(stripped)")
    }

    // style.txt is one "category\ttext" line per sample. Strip invisibles from each line;
    // drop it only if a disallowed scalar survives that. Clean lines are carried over
    // byte-for-byte.
    private static func sanitizeStyle(_ file: URL, backup: BackupRequest) -> Outcome {
        guard let data = try? Data(contentsOf: file) else { return .failed }
        guard !data.isEmpty else { return .unchanged("store-sanitize style.txt: empty, nothing to do") }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unchanged("store-sanitize style.txt: not UTF-8, left as-is")
        }
        var kept: [String] = []
        var keptSamples = 0, dropped = 0, stripped = 0
        for line in text.components(separatedBy: "\n") {
            // Blank lines are structural (the file opens with one) — carry them over
            // untouched so a clean file round-trips byte-for-byte.
            if line.isEmpty { kept.append(line); continue }
            let cleaned = TextSanitizer.strippingInvisibles(line)
            guard !cleaned.isEmpty, TextSanitizer.isClean(cleaned) else { dropped += 1; continue }
            if cleaned != line { stripped += 1 }
            kept.append(cleaned)
            keptSamples += 1
        }
        guard dropped > 0 || stripped > 0 else {
            return .unchanged("store-sanitize style.txt: already clean (\(keptSamples) samples)")
        }
        guard let out = kept.joined(separator: "\n").data(using: .utf8),
              backup(), writeAtomically(out, to: file) else { return .failed }
        return .done("store-sanitize style.txt: kept \(keptSamples), dropped \(dropped), stripped \(stripped)")
    }

    // Just the two fields that can reach a prompt, so an entry can be judged without
    // committing to the rest of the schema (which TopicMemory owns).
    private struct TopicProbe: Decodable {
        let keys: [String]?
        let note: String?
    }

    // topics.json is an array of TopicEntry objects. Strip invisibles out of the match keys
    // and the resurfacing note; drop the entry only if something disallowed survives.
    // Surviving entries keep every other field untouched, unknown ones included. Parsed
    // twice on purpose: JSONDecoder for the text (exact strings — see the note above about
    // JSONSerialization eating a leading U+FEFF), JSONSerialization for the objects to
    // re-emit. The two text fields are written back from the DECODED values, never from
    // JSONSerialization's own copy of them.
    private static func sanitizeTopics(_ file: URL, backup: BackupRequest) -> Outcome {
        guard let data = try? Data(contentsOf: file) else { return .failed }
        guard !data.isEmpty else { return .unchanged("store-sanitize topics.json: empty, nothing to do") }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let probes = try? JSONDecoder().decode([TopicProbe].self, from: data),
              probes.count == array.count else {
            return .unchanged("store-sanitize topics.json: unreadable, left as-is")
        }
        var stripped = 0
        let kept = zip(array, probes).compactMap { entry, probe -> [String: Any]? in
            let note = TextSanitizer.strippingInvisibles(probe.note ?? "")
            let keys = (probe.keys ?? []).map(TextSanitizer.strippingInvisibles)
            guard TextSanitizer.isClean(note), keys.allSatisfy(TextSanitizer.isClean) else { return nil }
            var out = entry
            if note != probe.note ?? "" || keys != probe.keys ?? [] {
                stripped += 1
                if entry["note"] != nil { out["note"] = note }
                if entry["keys"] != nil { out["keys"] = keys }
            }
            return out
        }
        let dropped = array.count - kept.count
        guard dropped > 0 || stripped > 0 else {
            return .unchanged("store-sanitize topics.json: already clean (\(kept.count) entries)")
        }
        guard let out = try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys]),
              backup(), writeAtomically(out, to: file) else { return .failed }
        return .done("store-sanitize topics.json: kept \(kept.count), dropped \(dropped), stripped \(stripped)")
    }

    // The two fields whose contents would be trained on.
    private struct TrainingProbe: Decodable {
        let context: String?
        let suggestion: String?
    }

    // training.jsonl is one JSON object per line and runs to megabytes, so it is streamed
    // rather than slurped. Each row's decoded `context` and `suggestion` have invisibles
    // stripped and are dropped only if something disallowed survives — decoded, because
    // the raw line stores the offenders escaped ("\u001c"), which is perfectly clean text
    // until JSON unescapes it.
    //
    // A row that needed no stripping is written back byte-identical, so nothing else about
    // it shifts. A row that did is re-serialized with the two text fields replaced by
    // their stripped values and every other field carried across untouched.
    private static func sanitizeTraining(_ file: URL, backup: BackupRequest) -> Outcome {
        let fm = FileManager.default
        guard let input = try? FileHandle(forReadingFrom: file) else { return .failed }
        defer { try? input.close() }
        let tmp = tempSibling(of: file)
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: tmp) else {
            try? fm.removeItem(at: tmp)
            return .failed
        }

        var kept = 0, dropped = 0, unparseable = 0, stripped = 0
        var pending = Data()
        var failed = false
        let decoder = JSONDecoder()

        func flush(_ line: Data) {
            guard !line.isEmpty else { return }
            guard let row = try? decoder.decode(TrainingProbe.self, from: line) else {
                unparseable += 1
                return
            }
            let context = row.context ?? ""
            let suggestion = row.suggestion ?? ""
            let cleanContext = TextSanitizer.strippingInvisibles(context)
            let cleanSuggestion = TextSanitizer.strippingInvisibles(suggestion)
            guard TextSanitizer.isClean(cleanContext), TextSanitizer.isClean(cleanSuggestion) else {
                dropped += 1
                return
            }
            var out: Data
            if cleanContext == context, cleanSuggestion == suggestion {
                out = line                                  // untouched: byte-identical
            } else {
                guard var object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    dropped += 1
                    return
                }
                if object["context"] != nil { object["context"] = cleanContext }
                if object["suggestion"] != nil { object["suggestion"] = cleanSuggestion }
                guard let reencoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                    dropped += 1
                    return
                }
                out = reencoded
                stripped += 1
            }
            out.append(0x0A)
            do { try output.write(contentsOf: out) } catch { failed = true }
            kept += 1
        }

        // `try?` here would turn a mid-file READ ERROR into an ordinary end-of-file and
        // commit a silently truncated corpus over the original. An I/O failure has to
        // abort the whole pass so the original is left exactly as it was and the version
        // stays unstamped for the next launch to retry.
        while !failed {
            let chunk: Data?
            do { chunk = try input.read(upToCount: 1 << 16) } catch { failed = true; break }
            guard let chunk, !chunk.isEmpty else { break }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                flush(Data(pending[pending.startIndex..<nl]))
                // Re-base the leftover: a Data slice keeps the parent's indices, and the
                // remainder is at most one line, so the copy is free.
                pending = Data(pending[pending.index(after: nl)...])
                if failed { break }
            }
        }
        if !failed { flush(pending) }          // trailing row with no final newline
        try? output.close()

        guard !failed else {
            try? fm.removeItem(at: tmp)
            return .failed
        }
        // Nothing to fix: throw the rewrite away rather than back up and replace a file
        // that would come out byte-identical.
        guard dropped > 0 || stripped > 0 || unparseable > 0 else {
            try? fm.removeItem(at: tmp)
            return .unchanged("store-sanitize training.jsonl: already clean (\(kept) rows)")
        }
        guard backup(), (try? fm.replaceItemAt(file, withItemAt: tmp)) != nil else {
            try? fm.removeItem(at: tmp)
            return .failed
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let note = unparseable > 0 ? ", \(unparseable) unparseable" : ""
        return .done("store-sanitize training.jsonl: kept \(kept), dropped \(dropped), stripped \(stripped)\(note)")
    }

    // feedback.json and router.json carry no text — they carry a verdict built from
    // rejections that never happened. Both loaders treat a missing file as "no history
    // yet" and fall back to their initial state (FeedbackMemory: empty outcome/word
    // windows; RouterMemory: 50/50 share, no rewards, unlocked), which is exactly the
    // state we want, so removing the file IS the reset.
    private static func resetStore(_ file: URL, backup: BackupRequest) -> Outcome {
        guard backup() else { return .failed }
        do { try FileManager.default.removeItem(at: file) } catch { return .failed }
        return .done("store-sanitize \(file.lastPathComponent): reset to initial state (backed up)")
    }

    // MARK: - Backup + atomic write

    // Copy `file` beside itself as "<name>.pre-sanitize-YYYYMMDD.bak", 0600. An existing
    // backup is never overwritten — the original of record is whatever was saved first,
    // so a second run on the same day takes a "-2", "-3", … suffix instead.
    private static func makeBackup(of file: URL) -> URL? {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let stamp = formatter.string(from: Date())
        let dir = file.deletingLastPathComponent()
        let base = file.lastPathComponent

        var backup = dir.appendingPathComponent("\(base).pre-sanitize-\(stamp).bak")
        var suffix = 2
        while fm.fileExists(atPath: backup.path) {
            backup = dir.appendingPathComponent("\(base).pre-sanitize-\(stamp)-\(suffix).bak")
            suffix += 1
            if suffix > 100 { return nil }
        }
        do { try fm.copyItem(at: file, to: backup) } catch { return nil }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup
    }

    private static func tempSibling(of file: URL) -> URL {
        file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).sanitize-\(UUID().uuidString).tmp")
    }

    // Write via a sibling temp file + replace, so a crash mid-rewrite can never leave a
    // truncated store behind. 0600 is re-applied afterwards because replaceItemAt does
    // not necessarily carry the original's mode across.
    private static func writeAtomically(_ data: Data, to file: URL) -> Bool {
        let fm = FileManager.default
        let tmp = tempSibling(of: file)
        do { try data.write(to: tmp, options: .atomic) } catch {
            try? fm.removeItem(at: tmp)
            return false
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        guard (try? fm.replaceItemAt(file, withItemAt: tmp)) != nil else {
            try? fm.removeItem(at: tmp)
            return false
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }
}
