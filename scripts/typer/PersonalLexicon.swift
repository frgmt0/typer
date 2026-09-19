import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Function words and other ultra-common English that say nothing about a person's
// vocabulary. Biasing the model toward "the" or "with" would be pure noise, so they
// never enter the lexicon at all.
private let lexiconStopWords: Set<String> = [
    "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her",
    "was", "one", "our", "out", "day", "get", "has", "him", "his", "how", "man", "new",
    "now", "old", "see", "two", "way", "who", "boy", "did", "its", "let", "put", "say",
    "she", "too", "use", "that", "with", "have", "this", "will", "your", "from", "they",
    "know", "want", "been", "good", "much", "some", "time", "very", "when", "come",
    "here", "just", "like", "long", "make", "many", "more", "only", "over", "such",
    "take", "than", "them", "well", "were", "what", "then", "into", "also", "about",
    "after", "again", "could", "every", "first", "found", "going", "great", "their",
    "there", "these", "thing", "think", "those", "three", "where", "which", "while",
    "would", "should", "really", "because", "before", "between", "people", "right",
    "still", "being", "doing", "yeah", "okay", "dont", "didnt", "thats", "youre",
    "ive", "im", "its", "isnt", "wont", "cant", "gonna", "wanna", "something",
    "anything", "everything", "nothing", "someone", "anyone", "everyone",
]

// Persistent, on-device frequency table of the words the user actually types.
// The top of the table — their distinctive vocabulary — is sent with each
// completion request, where the helper gives those words a mild logit boost.
// Entirely local: ~/Library/Application Support/typer/lexicon.json, 0600, clearable.
final class PersonalLexicon {
    private let url: URL
    private let queue = DispatchQueue(label: "typer.lexicon", qos: .utility)
    // `counts` mirrors lexicon.json, guarded by `lock`. topWords() runs on the main
    // thread on the generation hot path, so it serves a cached string and never
    // recomputes (or touches disk) more than once a minute.
    private let lock = NSLock()
    private var counts: [String: Int]?
    private var cachedTop = ""
    private var cachedTopAt = Date.distantPast
    private var saveScheduled = false

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("lexicon.json")
    }

    private func loadedCounts() -> [String: Int] {
        if counts == nil {
            counts = (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        }
        return counts!
    }

    // The shape a lexicon entry must have, as a pure check so the write path, the read
    // path and the store migration can never disagree: letters (plus inner apostrophes)
    // only, no disallowed scalars, and no held-key run. `hasHeldKeyRun` is what keeps
    // auto-repeat artifacts like "wwwww" or "aaaaaaaa" — a key leaned on, not a word —
    // out of the bias pool.
    static func isAcceptableWord(_ w: String) -> Bool {
        guard !w.isEmpty, w.first != "'", w.last != "'" else { return false }
        guard TextSanitizer.isClean(w), !TextSanitizer.hasHeldKeyRun(w) else { return false }
        return w.allSatisfy { $0.isLetter || $0 == "'" }
    }

    // Words eligible for the lexicon: letters (plus inner apostrophe), 4–24 chars,
    // not a stop word. Anything with digits, URLs, paths, emails never qualifies —
    // both for privacy and because token-biasing them would be useless. Control
    // characters and held-key runs are rejected outright: a stray arrow key used to
    // split a word here and leave the fragment behind, and a leaned-on key used to
    // enter the table as its own "word".
    private func eligibleWords(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && $0 != "'" }.compactMap { raw in
            let w = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard w.count >= 4, w.count <= 24, !lexiconStopWords.contains(w),
                  Self.isAcceptableWord(w) else { return nil }
            return w
        }
    }

    func learn(from text: String) {
        // Invisible formatting would otherwise split a word in two ("ca<U+200E>fe" →
        // "ca", "fe") and enter both halves as vocabulary. It is not a character anyone
        // typed, so it comes out before the text is split at all.
        let words = eligibleWords(in: TextSanitizer.strippingInvisibles(text))
        guard !words.isEmpty else { return }
        lock.lock()
        var c = loadedCounts()
        for w in words { c[w, default: 0] += 1 }
        // Decay instead of a hard cap: when the table grows large, halve every count
        // and drop the ones that fall to zero. Old one-off words age out; the user's
        // true favorites survive indefinitely.
        if c.count > 6000 {
            c = c.compactMapValues { $0 / 2 == 0 ? nil : $0 / 2 }
        }
        counts = c
        cachedTopAt = .distantPast      // top list may have changed
        let snapshot = c
        let shouldSave = !saveScheduled
        saveScheduled = true
        lock.unlock()
        if shouldSave {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.saveScheduled = false; let latest = self.counts ?? snapshot; self.lock.unlock()
                guard let d = try? JSONEncoder().encode(latest) else { return }
                try? d.write(to: self.url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
            }
        }
    }

    // Space-separated top-N words (most frequent first) with at least 3 uses —
    // the user's distinctive vocabulary, ready to drop into a helper request.
    // The string is intentionally stable for ~60s: the helper rebuilds its bias
    // table only when this changes.
    func topWords(_ n: Int = 48) -> String {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(cachedTopAt) < 60 { return cachedTop }
        let c = loadedCounts()
        // Filter on read as well as on write: lexicon.json is a plain JSON file the
        // user can hand-edit, and pre-sanitizer installs left artifacts in it. Nothing
        // malformed may reach the prompt or the helper's bias table.
        cachedTop = c.filter { $0.value >= 3 && Self.isAcceptableWord($0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(n).map { $0.key }.joined(separator: " ")
        cachedTopAt = Date()
        return cachedTop
    }

    func wordCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return loadedCounts().filter { $0.value >= 3 && Self.isAcceptableWord($0.key) }.count
    }

    func clear() {
        lock.lock()
        counts = [:]
        cachedTop = ""
        cachedTopAt = .distantPast
        lock.unlock()
        queue.async { try? FileManager.default.removeItem(at: self.url) }
    }
}
