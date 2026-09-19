import Foundation

// Two-model graded-reward bandit: race our own models against each other and lock the winner.
//
// We ship two candidate models — "raw" (the base) and "distill" (Gemma-distilled) — and route
// each generation to one of them at random, starting 50/50. Every resolved suggestion pays a
// GRADED reward to the model that produced it:
//
//     Tab / backtick accept          -> 1.0   (ideal: the user took it outright)
//     type-through of N words        -> 0.25 * N, capped at 1.0  (loosely followed; the
//                                        suggestion wasn't far off, the user typed some of it)
//     shown but ignored              -> 0.0
//
// The share shifts toward whichever model earns the higher average reward. When one model's
// share crosses the lock threshold (80%) it WINS: the router commits to it and stops exploring.
// This is the RLHF-style preference loop the user asked for — real accept/type-through feedback
// picks the model, and once preference is decisive we keep the preferred one.
//
// Bootstrap: with fewer than two candidate models in Models/, the router just serves whatever
// single model is present (no race). Gemma is no longer an arm — the two 0.6B models both beat
// it on the registers people actually type in, at a fraction of the latency and RAM.
final class ModelRouter {
    enum Pick: String, Codable { case a, b }

    private let cfg: TyperConfig
    let clientA: LlamaClient
    let clientB: LlamaClient?           // nil when only one candidate model is installed
    let nameA: String
    let nameB: String?
    private let mem: RouterMemory

    // Device-tiered model lineup. "s" is the local 0.6B two-model race that ships with the app.
    // "m" (1.7B) and "l" (4B) are single higher-quality models served straight (no race), each
    // fetched on demand the first time it's chosen and cached in Models/. Hosted on Hugging Face
    // (typer-org/typer-1). The tier the user picks is recommended from their RAM at onboarding.
    // CPU performance tiers, derived from the count of performance cores on the machine.
    // Used to recommend the largest model the hardware can actually run at a usable latency.
    enum CPUTier: Int, Comparable {
        case low = 0       // ≤2 perf cores (base M-series, older Intel)
        case standard = 1  // 3–5 perf cores (M Pro class)
        case high = 2      // 6+ perf cores (M Max / Ultra / high-core Intel)
        static func < (l: CPUTier, r: CPUTier) -> Bool { l.rawValue < r.rawValue }
    }

    struct ModelTier {
        let id: String              // "m" | "l"
        let file: String            // filename under Models/
        let repo: String            // Hugging Face repo, e.g. "typer-org/typer-1"
        let quantFile: String       // GGUF file within the repo (== file here, but named for clarity)
        let url: String             // HF download URL
        let label: String           // human label
        let approxMB: Int           // download-size hint for the UI
        let sizeBytes: Int64        // exact on-disk download size for disk-space pre-check + validation
        let runtimeMemBytes: Int64  // resident memory the loaded model needs (weights + KV headroom)
        let isBaseModel: Bool       // true = pretrained base (no instruct tuning); the "s" tier ships base+race
        let minMemoryGB: Int        // installed-RAM floor below which this tier is not recommended
        let recommendedCPUTier: CPUTier  // perf-core class at/above which this tier is recommended
    }
    static let downloadTiers: [ModelTier] = [
        ModelTier(id: "m", file: "typer-1m.gguf",
                  repo: "typer-org/typer-1", quantFile: "typer-1m.gguf",
                  url: "https://huggingface.co/typer-org/typer-1/resolve/main/typer-1m.gguf",
                  label: "typer-1m (1.7B)", approxMB: 1834,
                  sizeBytes: 1_834 * 1_048_576, runtimeMemBytes: 3_200 * 1_048_576,
                  isBaseModel: false, minMemoryGB: 14, recommendedCPUTier: .standard),
        ModelTier(id: "l", file: "typer-1l.gguf",
                  repo: "typer-org/typer-1", quantFile: "typer-1l.gguf",
                  url: "https://huggingface.co/typer-org/typer-1/resolve/main/typer-1l.gguf",
                  label: "typer-1l (4B)", approxMB: 4366,
                  sizeBytes: 4_366 * 1_048_576, runtimeMemBytes: 6_400 * 1_048_576,
                  isBaseModel: false, minMemoryGB: 24, recommendedCPUTier: .high),
    ]
    static func tier(_ id: String) -> ModelTier? { downloadTiers.first { $0.id == id } }
    static var modelsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/Models")
    }
    static func tierPath(_ t: ModelTier) -> String { modelsDir.appendingPathComponent(t.file).path }
    static func tierInstalled(_ id: String) -> Bool {
        guard let t = tier(id) else { return false }
        return FileManager.default.fileExists(atPath: tierPath(t))
    }

    // MARK: - Hardware recommendation (#11)

    // Installed physical memory, in whole GB.
    static var installedMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0).rounded())
    }

    // Performance-core count via sysctl hw.perflevel0.physicalcpu (Apple silicon). Falls back to
    // hw.physicalcpu on Intel where perflevel0 is absent. 0 on failure → treated as the low tier.
    static func performanceCoreCount() -> Int {
        func sysctlInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
        }
        if let c = sysctlInt("hw.perflevel0.physicalcpu"), c > 0 { return c }
        if let c = sysctlInt("hw.physicalcpu"), c > 0 { return c }
        return 0
    }

    static var cpuTier: CPUTier {
        switch performanceCoreCount() {
        case 6...:    return .high
        case 3...5:   return .standard
        default:      return .low
        }
    }

    // The small base/race tier that always ships with the app. Modeled as a synthetic tier so the
    // recommendation logic can reason about every option uniformly.
    static let smallTier = ModelTier(
        id: "s", file: "", repo: "typer-org/typer-1", quantFile: "",
        url: "", label: "typer-1s (0.6B)", approxMB: 600,
        sizeBytes: 600 * 1_048_576, runtimeMemBytes: 900 * 1_048_576,
        isBaseModel: true, minMemoryGB: 0, recommendedCPUTier: .low)

    static var allTiers: [ModelTier] { [smallTier] + downloadTiers }

    // Largest tier whose RAM + CPU floors the machine clears. Walks biggest→smallest and returns
    // the first that fits; the small tier (no floors) always fits, so this never returns nil.
    static func recommendedTier() -> ModelTier {
        let ram = installedMemoryGB
        let cpu = cpuTier
        for t in allTiers.sorted(by: { $0.runtimeMemBytes > $1.runtimeMemBytes }) {
            if ram >= t.minMemoryGB && cpu >= t.recommendedCPUTier { return t }
        }
        return smallTier
    }

    // A "you could run a bigger model" notice: non-nil when the recommended tier is larger than
    // what's currently selected/served. The UI shows this once so a 32 GB Mac on the small model
    // learns it can move up. Returns the recommended tier to offer.
    static func upgradeRecommendation(currentVariant: String) -> ModelTier? {
        let rec = recommendedTier()
        guard rec.id != "s" else { return nil }
        // Order the ids small→large so we can compare "is the recommendation bigger than current".
        let order = ["s": 0, "m": 1, "l": 2]
        let cur = order[currentVariant] ?? 0
        let recRank = order[rec.id] ?? 0
        return recRank > cur ? rec : nil
    }

    // True for this router instance when it's serving a single downloaded tier (no race).
    let isLarge: Bool

    init(cfg: TyperConfig) {
        self.cfg = cfg
        // Medium/Large tier: serve the single downloaded model directly, no A/B race — but only
        // if the user picked it AND it's actually downloaded; otherwise fall back to the small race.
        if let t = ModelRouter.tier(cfg.modelVariant), ModelRouter.tierInstalled(t.id) {
            isLarge = true
            nameA = t.file
            clientA = LlamaClient(cfg: cfg, modelPath: ModelRouter.tierPath(t))
            nameB = nil
            clientB = nil
            mem = RouterMemory(cfg: cfg)
            return
        }
        isLarge = false
        let (a, b) = ModelRouter.resolveModels(cfg)
        nameA = a.map { ($0 as NSString).lastPathComponent } ?? "unknown"
        clientA = LlamaClient(cfg: cfg, modelPath: a)
        if cfg.typer1Enabled, let bPath = b {
            nameB = (bPath as NSString).lastPathComponent
            clientB = LlamaClient(cfg: cfg, modelPath: bPath)
        } else {
            nameB = nil
            clientB = nil
        }
        mem = RouterMemory(cfg: cfg)
    }

    // Two arms present and enabled → an actual race is running.
    var racing: Bool { clientB != nil }
    // The model the menu should report as "current default" (the leading / locked arm).
    var defaultName: String { mem.leader == .b ? (nameB ?? nameA) : nameA }
    var currentShareA: Double { racing ? mem.shareA : 1.0 }

    // Warm the leading arm at launch; the other spawns lazily on its first pick, so a
    // low-share or already-locked loser never pays its memory until it actually serves.
    func warmUp() { client(for: mem.leader).warmUp() }

    // Decide which model serves this generation. Once locked, always the winner; otherwise
    // arm A with probability shareA, else arm B. The chosen model serves the whole
    // generation (and its prefetch continuations) so one suggestion is never a mix.
    func pick() -> (client: LlamaClient, pick: Pick, name: String) {
        guard clientB != nil else { return (clientA, .a, nameA) }
        if let locked = mem.lockedPick {
            return (client(for: locked), locked, modelName(for: locked))
        }
        let p: Pick = Double.random(in: 0..<1) < mem.shareA ? .a : .b
        return (client(for: p), p, modelName(for: p))
    }

    func client(for pick: Pick) -> LlamaClient {
        (pick == .b ? clientB : nil) ?? clientA
    }

    func modelName(for pick: Pick) -> String {
        (pick == .b ? nameB : nil) ?? nameA
    }

    // Feed one resolved suggestion back into the bandit as a graded reward (see the table at
    // the top). Tab/backtick is the ideal outcome; a type-through pays partial credit for the
    // words the user actually followed; an ignored suggestion pays nothing.
    func record(pick: Pick, accepted: Bool, kind: String, words: Int) {
        guard racing else { return }
        let reward: Double
        if accepted && (kind == "tab" || kind == "backtick") {
            reward = 1.0
        } else {
            reward = min(1.0, RouterMemory.rewardPerWord * Double(max(0, words)))
        }
        mem.record(pick: pick, reward: reward)
    }

    // One line for the status-bar menu, nil when there is no race to report on.
    func statusSummary() -> String? {
        guard racing else { return nil }
        return mem.summary(nameA: short(nameA), nameB: short(nameB ?? "b"))
    }

    private func short(_ n: String) -> String {
        // "typer-1-distill.gguf" -> "distill"; fall back to the stem.
        let stem = (n as NSString).deletingPathExtension
        if let r = stem.range(of: "typer-1-") { return String(stem[r.upperBound...]) }
        return stem
    }

    // Structured race state for the custom menu UI: short names, arm-A share, average reward
    // per arm, and the winner's name once locked. nil when there's no race to show.
    func raceState() -> (a: String, b: String, aShare: Double, aReward: Double, bReward: Double, lockedName: String?)? {
        guard racing else { return nil }
        let a = short(nameA), b = short(nameB ?? "b")
        let locked = mem.lockedPick.map { $0 == .a ? a : b }
        let (ra, rb) = mem.rewards()
        return (a, b, mem.shareA, ra, rb, locked)
    }

    // Wipe the race state (share + reward windows + any lock) — also called by "Reset All Data".
    // Also drops the derived personalization cache: "Reset All Data" clears the lexicon it is
    // built from, so the cached word list must rebuild from the now-empty vocabulary. No
    // separate state file to remove — it is derived in-memory from lexicon.json.
    func reset() { mem.reset(); personalization.invalidate() }

    // Kill both arms' helper processes — called before swapping the router on a model switch.
    func shutdown() { clientA.stop(); clientB?.stop() }

    // MARK: - Personalization (#10, Wave 4 interim — NO LoRA)
    //
    // The personalization seam, owned in one place: from the user's high-frequency words
    // (PersonalLexicon) we derive the strength-scaled, frequency-ordered word list that the
    // request path already carries (`LlamaClient.request(lexicon:)`). The helper tokenizes it
    // and applies a flat per-word first-token boost (`PersonalizationBias.maxBoost`).
    //
    // There used to be a second, parallel artifact here — a Swift-side `[token: Float]` bias
    // map built through an injected tokenizer. It had no caller, and the tokenizer was never
    // injectable (the closure that fed it hard-returned `[]`), so it computed an empty map
    // nobody read. It is gone; the lexicon string is, and always was, the live mechanism.
    //
    // OFF (empty) when `strength == 0` — today's default — so personalization adds nothing
    // until the user opts in, and it re-derives whenever the strength bucket or the underlying
    // word list changes (cached otherwise; this runs on the generation hot path).
    private let personalization = PersonalizationBias()

    // The strength-scaled lexicon word list for the live request path. `strength` is read at
    // call time (not from the init-time cfg copy) so a slider change takes effect immediately.
    // Empty when strength == 0 or the feature flag is off.
    func lexiconString(words: String, strength: Double) -> String {
        personalization.lexiconString(words: words, strength: strength)
    }

    // Synchronously persist race state — called on app terminate so a winner locked
    // in the last debounce window isn't lost on quit.
    func flush() { mem.flush() }

    // The two arms: every Models/ file whose name begins with typer1ModelGlob (default
    // "typer-1"), sorted, first two taken as A and B. Gemma and anything else is ignored.
    // Fewer than two matches → fall back to the single configured/available model (no race).
    static func resolveModels(_ cfg: TyperConfig) -> (a: String?, b: String?) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/Models")
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".gguf") }.sorted()
        let glob = cfg.typer1ModelGlob.lowercased()
        let arms = glob.isEmpty ? [] : names.filter { $0.lowercased().hasPrefix(glob) }
        func path(_ n: String) -> String { dir.appendingPathComponent(n).path }

        if arms.count >= 2 { return (path(arms[0]), path(arms[1])) }
        // Not enough candidates to race: serve a single model (the configured default if it
        // exists, else the lone candidate, else any installed gguf).
        let single: String?
        if arms.count == 1 { single = path(arms[0]) }
        else if !cfg.modelPath.isEmpty, fm.fileExists(atPath: cfg.modelPath) { single = cfg.modelPath }
        else { single = names.first.map(path) }
        return (single, nil)
    }
}

// Persistent race state in ~/Library/Application Support/typer/router.json (0600, clearable):
// the live share of arm A plus a rolling window of graded rewards per arm, and the lock once a
// winner is decided. Same debounced, main-thread-read / background-write shape as FeedbackMemory.
final class RouterMemory {
    // Graded-reward constants. rewardPerWord credits a loose type-through ~0.25/word; lockHigh
    // is the share at which a model wins outright (and lockLow = 1 - lockHigh for the other arm).
    static let rewardPerWord = 0.25
    private let lockHigh = 0.80
    private var lockLow: Double { 1 - lockHigh }

    private struct Snapshot: Codable {
        var shareA: Double
        var rewardsA: [Double]          // newest last; graded reward in [0, 1]
        var rewardsB: [Double]
        var sinceLastAdjust: Int
        var locked: String?             // nil, "a", or "b" once a winner is committed
    }

    private let url: URL
    private let queue = DispatchQueue(label: "typer.router", qos: .utility)

    private let step: Double            // share move per adjust
    private let minSamples: Int         // per-arm samples + cooldown before moving the share
    private let window = 100
    private let tolerance = 0.02        // reward gap below which we hold (avoid thrash on noise)

    private var shareValue = 0.5        // start 50/50: both models are new, no prior
    private var rewardsA: [Double] = []
    private var rewardsB: [Double] = []
    private var sinceLastAdjust = 0
    private var lockedValue: String?
    private var loaded = false
    private var saveScheduled = false

    init(cfg: TyperConfig) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("router.json")
        step = cfg.typer1RatchetStep
        minSamples = cfg.typer1RatchetMinSamples
    }

    var shareA: Double { loadIfNeeded(); return shareValue }
    var lockedPick: ModelRouter.Pick? {
        loadIfNeeded()
        switch lockedValue { case "a": return .a; case "b": return .b; default: return nil }
    }
    // Which arm is currently ahead (for warm-up + the menu's "default" label).
    var leader: ModelRouter.Pick {
        loadIfNeeded()
        if let l = lockedPick { return l }
        return shareValue >= 0.5 ? .a : .b
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let d = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Snapshot.self, from: d) else { return }
        shareValue = min(1, max(0, s.shareA))
        rewardsA = s.rewardsA
        rewardsB = s.rewardsB
        sinceLastAdjust = s.sinceLastAdjust
        lockedValue = s.locked
    }

    func record(pick: ModelRouter.Pick, reward: Double) {
        loadIfNeeded()
        guard lockedValue == nil else { return }       // race is over; nothing to learn
        if pick == .a {
            rewardsA.append(reward)
            if rewardsA.count > window { rewardsA.removeFirst(rewardsA.count - window) }
        } else {
            rewardsB.append(reward)
            if rewardsB.count > window { rewardsB.removeFirst(rewardsB.count - window) }
        }
        sinceLastAdjust += 1
        adjust()
        scheduleSave()
    }

    // Move the share toward the higher-reward arm once both arms have enough signal and a
    // cooldown has passed, then lock the winner if its share crosses the threshold.
    private func adjust() {
        guard rewardsA.count >= minSamples, rewardsB.count >= minSamples,
              sinceLastAdjust >= minSamples else { return }
        let mA = mean(rewardsA), mB = mean(rewardsB)
        if mA > mB + tolerance {
            shareValue = min(lockHigh, shareValue + step)
        } else if mB > mA + tolerance {
            shareValue = max(lockLow, shareValue - step)
        } else {
            return                                     // too close to call → hold the cooldown
        }
        sinceLastAdjust = 0
        if shareValue >= lockHigh { lockedValue = "a"; shareValue = 1.0 }
        else if shareValue <= lockLow { lockedValue = "b"; shareValue = 0.0 }
    }

    private func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }

    func rewards() -> (Double, Double) { loadIfNeeded(); return (mean(rewardsA), mean(rewardsB)) }

    func summary(nameA: String, nameB: String) -> String {
        loadIfNeeded()
        if let l = lockedValue {
            return "model: locked on \(l == "a" ? nameA : nameB) (race won)"
        }
        let pct = Int((shareValue * 100).rounded())
        func avg(_ xs: [Double]) -> String { xs.isEmpty ? "—" : String(format: "%.2f", mean(xs)) }
        return "model race: \(nameA) \(pct)% / \(nameB) \(100 - pct)% · reward \(avg(rewardsA)) vs \(avg(rewardsB))"
    }

    func reset() {
        shareValue = 0.5
        rewardsA = []
        rewardsB = []
        sinceLastAdjust = 0
        lockedValue = nil
        loaded = true
        queue.async { try? FileManager.default.removeItem(at: self.url) }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            // Re-read the latest state at fire time (state is main-thread-confined),
            // so a lock or share move landing inside the debounce window isn't lost.
            // Encode + write off-main to keep the main thread light.
            DispatchQueue.main.async {
                self.saveScheduled = false
                let snap = Snapshot(shareA: self.shareValue, rewardsA: self.rewardsA, rewardsB: self.rewardsB,
                                    sinceLastAdjust: self.sinceLastAdjust, locked: self.lockedValue)
                self.queue.async {
                    guard let d = try? JSONEncoder().encode(snap) else { return }
                    try? d.write(to: self.url, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
                }
            }
        }
    }

    // Synchronously persist the current state — used on app terminate so a winner
    // locked in the last debounce window survives a quit.
    func flush() {
        guard loaded else { return }
        let snap = Snapshot(shareA: shareValue, rewardsA: rewardsA, rewardsB: rewardsB,
                            sinceLastAdjust: sinceLastAdjust, locked: lockedValue)
        guard let d = try? JSONEncoder().encode(snap) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// Personalization word-list builder (spec §G.3 interim — NO LoRA). Turns the user's
// high-frequency words into the strength-scaled lexicon string the live request path already
// carries; the HELPER tokenizes it and applies the per-word first-token boost.
//
// There was a second channel here — a Swift-side `[token: Float]` map built through an
// injected tokenizer. Nothing ever called it and the tokenizer was never injectable, so it
// computed an empty map nobody read; it has been removed rather than left to look live.
//
// Strength (0..1) shapes personalization on one axis, breadth: how many of the user's words
// ride along (baseline 48 → cap 64 at full strength), matching the prior
// `personalizedLexicon()` behavior so strength 0 is a no-op and not a regression. Depth (the
// per-word boost) is deliberately NOT on the slider — see `maxBoost`.
//
// All state is main-thread-confined (it lives on the generation hot path, same as the rest of
// the router) and memoized on `(strengthBucket, words)`, so it only re-runs when the user
// moves the slider or their top-word list actually changes.
final class PersonalizationBias {
    // Gentle by design: a word on the list gets at most this first-token boost in the helper.
    // Far too small to force a word the model wouldn't otherwise consider — it breaks ties
    // toward the user's vocabulary and nothing more.
    // Read by the app's `personalizedLexiconBias()`, which is what puts it on the wire, so the
    // documented ceiling and the value actually sent can never drift apart.
    static let maxBoost: Float = 0.5
    private static let baseWords = 48
    private static let maxWords = 64

    private var cacheKey = ""              // "<bucket>|<words>" the cache was built for
    private var cachedString = ""

    // Bucket strength to one decimal so micro-jitter on a continuous slider doesn't thrash the
    // tokenizer; the visible effect is identical and the cache stays warm.
    private func key(_ words: String, _ strength: Double) -> String {
        let bucket = Int((min(1, max(0, strength)) * 10).rounded())
        return "\(bucket)|\(words)"
    }

    // Frequency-ordered word slice for the given strength. Strength 0 is OFF and returns
    // nothing: it used to return the full 48-word baseline, which meant the slider's zero
    // position still shipped every one of the user's words to the sampler. The count grows
    // from the 48-word baseline at the first non-zero strength toward the 64-word cap at
    // full strength. The caller has already gated on `lexiconEnabled`.
    private func scaledWords(_ words: String, _ strength: Double) -> [String] {
        let s = min(1, max(0, strength))
        guard s > 0 else { return [] }
        let n = Self.baseWords + Int((Double(Self.maxWords - Self.baseWords) * s).rounded())
        return words.split(separator: " ").prefix(n).map(String.init)
    }

    // The lexicon STRING channel: present at all strengths (it is the pre-existing
    // `lexiconEnabled` feature, gated by the caller). Strength only widens it.
    func lexiconString(words: String, strength: Double) -> String {
        rebuildIfNeeded(words: words, strength: strength)
        return cachedString
    }

    private func rebuildIfNeeded(words: String, strength: Double) {
        let k = key(words, strength)
        if k == cacheKey { return }
        cacheKey = k
        cachedString = scaledWords(words, strength).joined(separator: " ")
    }

    // Force a rebuild on the next query (slider moved past the cache bucket, or lexicon reset).
    func invalidate() { cacheKey = "" }
}
