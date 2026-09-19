import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// One distilled thing the user looked at on screen: the salient names/keywords plus a
// short snippet to resurface, NOT the raw page text.
struct TopicEntry: Codable {
    let at: Double          // epoch seconds
    let app: String
    let title: String
    let keys: [String]      // lowercased match keys (distinctive entity tokens)
    let note: String        // short human-readable snippet to fold back into a prompt
}

// Ambient topic memory: a small, on-device, distilled record of what the user has
// recently viewed (periodic OCR → entity extraction). Resurfaced into a prompt only
// when the user later types about one of the stored entities. Capped, 0600, clearable.
final class TopicMemory {
    private let url: URL
    private let maxEntries = 60
    private let queue = DispatchQueue(label: "typer.topics", qos: .utility)
    private let lock = NSLock()
    private var cached: [TopicEntry]?

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("topics.json")
    }

    private func entries() -> [TopicEntry] {
        lock.lock(); defer { lock.unlock() }
        if cached == nil {
            cached = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([TopicEntry].self, from: $0) } ?? []
        }
        return cached!
    }

    func record(_ rawEntry: TopicEntry) {
        guard !rawEntry.keys.isEmpty else { return }
        // OCR and AX text both drag invisible formatting in. It carries no meaning, so it
        // is removed rather than used as grounds to throw an otherwise-good entry away.
        let e = TopicEntry(at: rawEntry.at, app: rawEntry.app, title: rawEntry.title,
                           keys: rawEntry.keys.map(TextSanitizer.strippingInvisibles).filter { !$0.isEmpty },
                           note: TextSanitizer.strippingInvisibles(rawEntry.note))
        guard !e.keys.isEmpty else { return }
        // Both halves of the entry can end up in a prompt — the keys via the match, the
        // note verbatim — so a single bad scalar STILL there drops the whole entry. OCR is
        // the usual source of U+FFFD and private-use glyphs here.
        guard TopicMemory.isUsable(e) else { return }
        lock.lock()
        var all = cached ?? (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([TopicEntry].self, from: $0) } ?? []
        // Replace any prior capture of the same view (same app + title) so we keep the
        // freshest snapshot rather than piling up duplicates of a page left open.
        all.removeAll { $0.app == e.app && $0.title == e.title }
        all.append(e)
        if all.count > maxEntries { all.removeFirst(all.count - maxEntries) }
        cached = all
        lock.unlock()
        persist(all)
    }

    // An entry is usable only if every match key and the resurfacing note are clean —
    // the shared gate for both the write path and the read path, so a hand-edited or
    // pre-sanitizer topics.json can never feed a prompt.
    static func isUsable(_ e: TopicEntry) -> Bool {
        TextSanitizer.isClean(e.note) && e.keys.allSatisfy(TextSanitizer.isClean)
    }

    // The note for the most recent entry whose keys appear in `text`, or nil. This is
    // the "only when there's a clear entity match" gate.
    func relevant(to text: String) -> String? {
        let hay = " " + text.lowercased() + " "
        for e in entries().reversed() where TopicMemory.isUsable(e) {
            if e.keys.contains(where: { hay.contains($0) }) { return e.note }
        }
        return nil
    }

    func count() -> Int { entries().count }

    func clear() {
        lock.lock(); cached = []; lock.unlock()
        queue.async { try? FileManager.default.removeItem(at: self.url) }
    }

    private func persist(_ all: [TopicEntry]) {
        queue.async {
            guard let d = try? JSONEncoder().encode(all) else { return }
            try? d.write(to: self.url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
        }
    }
}

// Common/UI words that slip past entity + noun extraction and would cause spurious
// "you read about X" matches. Small on purpose.
private let topicStopWords: Set<String> = [
    "the","and","for","with","this","that","your","you","from","are","was","were","has",
    "have","had","will","would","can","could","more","most","here","there","what","when",
    "where","which","their","them","they","our","out","about","into","over","than","then",
    "review","reviews","home","page","menu","sign","search","login","settings","help",
    "terms","privacy","cookie","cookies","accept","share","follow","subscribe","news",
    "available","rated","support","click","button","close","open","loading",
]

// Distill OCR'd screen text + a window title into (match keys, resurfacing note) using
// Apple's on-device NaturalLanguage. Keys are the distinctive things the user is likely
// to mention later: named-entity tokens (brands/products/people/places) plus repeated
// content nouns (the topic/category). The note is the title plus the most informative
// sentence or two — what gets folded back into a prompt when a key is later typed.
func distillTopics(text raw: String, title rawTitle: String) -> (keys: [String], note: String) {
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = raw.replacingOccurrences(of: "\r", with: "\n")
    guard text.count >= 60 || title.count >= 6 else { return ([], "") }

    var keys = Set<String>()
    var phrases = Set<String>()   // entity phrases, for note sentence selection

    // 1) Named entities (people / places / orgs / products), joined.
    let nt = NLTagger(tagSchemes: [.nameType]); nt.string = text
    nt.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                     options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
        if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
            let s = String(text[range]).trimmingCharacters(in: .whitespaces)
            if s.count >= 3, s.count <= 40 {
                phrases.insert(s)
                for tok in s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where tok.count >= 4 {
                    let l = tok.lowercased(); if !topicStopWords.contains(l) { keys.insert(l) }
                }
                if s.contains(" "), s.count <= 24 { keys.insert(s.lowercased()) }
            }
        }
        return keys.count < 30
    }
    // 2) Repeated content nouns — the topic/category words ("headphones", "mortgage").
    var freq: [String: Int] = [:]
    let lt = NLTagger(tagSchemes: [.lexicalClass]); lt.string = text
    lt.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                     options: [.omitWhitespace, .omitPunctuation]) { tag, range in
        if tag == .noun {
            let l = String(text[range]).lowercased()
            if l.count >= 4, !topicStopWords.contains(l) { freq[l, default: 0] += 1 }
        }
        return true
    }
    for (w, n) in freq where n >= 2 { keys.insert(w) }
    if !title.isEmpty { phrases.insert(title) }
    guard !keys.isEmpty else { return ([], "") }

    // Note: title + up to two informative sentences that mention an entity.
    let phraseLower = phrases.map { $0.lowercased() }
    var sentences: [String] = []
    let st = NLTokenizer(unit: .sentence); st.string = text
    st.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
        let s = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 30, s.count <= 240, phraseLower.contains(where: { s.lowercased().contains($0) }) {
            sentences.append(s)
        }
        return sentences.count < 2
    }
    var note = title.isEmpty ? "" : title
    if !sentences.isEmpty { note += (note.isEmpty ? "" : " — ") + sentences.joined(separator: " ") }
    return (Array(keys.prefix(24)), String(note.prefix(300)))
}
