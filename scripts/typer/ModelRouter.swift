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

    // The large model the user can opt into: a single higher-quality ~1.2GB model served
    // straight (no race), for machines with the RAM. Lives at Models/typer-1l.gguf and is
    // fetched on demand (ModelDownloader). HF source for that download:
    static let largeModelFile = "typer-1l.gguf"
    static let largeModelURL = "https://huggingface.co/milosa/typer-1-v1/resolve/main/typer1-f16.gguf"
    static var modelsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/Models")
    }
    static var largeModelPath: String { modelsDir.appendingPathComponent(largeModelFile).path }
    static func largeModelInstalled() -> Bool { FileManager.default.fileExists(atPath: largeModelPath) }

    // True for this router instance when it's serving the large model (single model, no race).
    let isLarge: Bool

    init(cfg: TyperConfig) {
        self.cfg = cfg
        // Large variant: serve the single big model directly, no A/B race — but only if the
        // user picked it AND it's actually downloaded; otherwise fall back to the small race.
        if cfg.modelVariant == "large", ModelRouter.largeModelInstalled() {
            isLarge = true
            nameA = ModelRouter.largeModelFile
            clientA = LlamaClient(cfg: cfg, modelPath: ModelRouter.largeModelPath)
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
    func reset() { mem.reset() }

    // Kill both arms' helper processes — called before swapping the router on a model switch.
    func shutdown() { clientA.stop(); clientB?.stop() }

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
