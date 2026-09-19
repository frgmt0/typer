import AppKit
import ApplicationServices
import Foundation

// Per-app / per-domain quirk + custom-instruction overrides (spec D.5).
//
// An all-optional Codable record keyed by bundle id, plus `domain:<pattern>` rows for web
// fields. Persisted as a JSON sidecar at
//   ~/Library/Application Support/typer/app_overrides.json
// Resolution merges in-code defaults < user app override < user domain override, where any
// non-nil value wins (most specific last). The store exposes both the resolved view (what
// the engine uses) and the raw user view (so the settings UI can show inherited vs.
// overridden), per D.5.

struct AppOverrides: Codable, Equatable {
    var completionsDisabled: Bool?
    var midLineCompletionsDisabled: Bool?
    var autocorrectDisabled: Bool?
    var emojiCompletionsDisabled: Bool?
    var emojiSearchDisabled: Bool?
    var needsEnhancedUserInterface: Bool?
    var ignoreSizeThresholds: Bool?
    var requiresPasteAndMatchStyleWorkaround: Bool?
    var requiresNonBreakingSpaceWorkaround: Bool?
    var requiresBackspaceRightAfterPaste: Bool?
    var requiresSpaceKeyEventWorkaround: Bool?
    var stringInjectionChunkSize: Int?
    var fontSizeAdjustmentFactor: Double?
    var verticalAlignmentOffset: Double?
    var customInstructions: String?

    init() {}

    // Merge `other` on top of self: any non-nil field in `other` overrides this one's.
    func merged(over base: AppOverrides) -> AppOverrides {
        var r = base
        if let v = completionsDisabled { r.completionsDisabled = v }
        if let v = midLineCompletionsDisabled { r.midLineCompletionsDisabled = v }
        if let v = autocorrectDisabled { r.autocorrectDisabled = v }
        if let v = emojiCompletionsDisabled { r.emojiCompletionsDisabled = v }
        if let v = emojiSearchDisabled { r.emojiSearchDisabled = v }
        if let v = needsEnhancedUserInterface { r.needsEnhancedUserInterface = v }
        if let v = ignoreSizeThresholds { r.ignoreSizeThresholds = v }
        if let v = requiresPasteAndMatchStyleWorkaround { r.requiresPasteAndMatchStyleWorkaround = v }
        if let v = requiresNonBreakingSpaceWorkaround { r.requiresNonBreakingSpaceWorkaround = v }
        if let v = requiresBackspaceRightAfterPaste { r.requiresBackspaceRightAfterPaste = v }
        if let v = requiresSpaceKeyEventWorkaround { r.requiresSpaceKeyEventWorkaround = v }
        if let v = stringInjectionChunkSize { r.stringInjectionChunkSize = v }
        if let v = fontSizeAdjustmentFactor { r.fontSizeAdjustmentFactor = v }
        if let v = verticalAlignmentOffset { r.verticalAlignmentOffset = v }
        if let v = customInstructions { r.customInstructions = v }
        return r
    }

    var isEmpty: Bool { self == AppOverrides() }
}

// The persisted store: user app rows (keyed by bundle id) + user domain rows (keyed by a
// `domain:<pattern>` host fragment). In-code defaults live in `OverrideStore.defaults` and
// are merged underneath the user values during resolution.
final class OverrideStore {
    static let shared = OverrideStore()

    private let lock = NSLock()
    private(set) var apps: [String: AppOverrides] = [:]
    private(set) var domains: [String: AppOverrides] = [:]   // key WITHOUT the "domain:" prefix
    // Small per-(bundle|domain) resolution cache; invalidated on any write.
    private var resolvedCache: [String: AppOverrides] = [:]

    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/typer/app_overrides.json")

    // Built-in, shipped quirk defaults. Conservative: only well-known cases. Later waves
    // extend this table; W0 seeds a couple of safe, documented entries.
    static let defaults: [String: AppOverrides] = {
        var d: [String: AppOverrides] = [:]
        // Microsoft apps historically need AXEnhancedUserInterface toggled to expose AX text.
        var word = AppOverrides(); word.needsEnhancedUserInterface = true
        d["com.microsoft.Word"] = word
        var outlook = AppOverrides(); outlook.needsEnhancedUserInterface = true
        d["com.microsoft.Outlook"] = outlook
        // (docs.google.com used to be routed through TextMirror here. Nothing on the caret
        // path has read `textMirroringEnabled` since the mirror tier was disabled, so the
        // field and the row are gone; Docs is handled by the screen-reader-support prompt
        // in TyperApp+Caret, after which the ordinary bounds/marker tiers work.)
        return d
    }()

    private init() { load() }

    // MARK: - Persistence

    private struct Wire: Codable {
        var apps: [String: AppOverrides]
        var domains: [String: AppOverrides]
    }

    func load() {
        lock.lock(); defer { lock.unlock() }
        resolvedCache.removeAll()
        guard let data = try? Data(contentsOf: OverrideStore.url),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            apps = [:]; domains = [:]; return
        }
        apps = wire.apps
        domains = wire.domains
    }

    private func persistLocked() {
        let wire = Wire(apps: apps, domains: domains)
        guard let data = try? JSONEncoder().encode(wire) else { return }
        let dir = OverrideStore.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: OverrideStore.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: OverrideStore.url.path)
    }

    // MARK: - Reads

    // The user's raw override for a bundle (no defaults merged) — "overridden" view.
    func userApp(_ bundle: String) -> AppOverrides {
        lock.lock(); defer { lock.unlock() }
        return apps[bundle] ?? AppOverrides()
    }

    // The user's raw override for a web domain pattern.
    func userDomain(_ pattern: String) -> AppOverrides {
        lock.lock(); defer { lock.unlock() }
        return domains[normalizeDomain(pattern)] ?? AppOverrides()
    }

    // The resolved, effective overrides for a bundle and (optional) web host:
    // defaults < user app < matching user domain (and the in-code domain default).
    func resolved(bundle: String, host: String? = nil) -> AppOverrides {
        let cacheKey = bundle + "\u{1}" + (host ?? "")
        lock.lock(); defer { lock.unlock() }
        if let cached = resolvedCache[cacheKey] { return cached }

        var result = AppOverrides()
        // 1. in-code app default
        if let d = OverrideStore.defaults[bundle] { result = d.merged(over: result) }
        // 2. user app override
        if let u = apps[bundle] { result = u.merged(over: result) }
        // 3. domain rows (in-code default then user), most-specific match by suffix
        if let host, !host.isEmpty {
            for (pat, ov) in OverrideStore.defaults where pat.hasPrefix("domain:") {
                if hostMatches(host, pattern: String(pat.dropFirst("domain:".count))) {
                    result = ov.merged(over: result)
                }
            }
            for (pat, ov) in domains where hostMatches(host, pattern: pat) {
                result = ov.merged(over: result)
            }
        }
        resolvedCache[cacheKey] = result
        return result
    }

    // MARK: - Writes

    func setApp(_ bundle: String, _ ov: AppOverrides) {
        guard !bundle.isEmpty else { return }
        lock.lock()
        if ov.isEmpty { apps[bundle] = nil } else { apps[bundle] = ov }
        resolvedCache.removeAll()
        persistLocked()
        lock.unlock()
    }

    func setDomain(_ pattern: String, _ ov: AppOverrides) {
        let key = normalizeDomain(pattern)
        guard !key.isEmpty else { return }
        lock.lock()
        if ov.isEmpty { domains[key] = nil } else { domains[key] = ov }
        resolvedCache.removeAll()
        persistLocked()
        lock.unlock()
    }

    // Convenience for the common single-field case (e.g. settings toggles).
    func setCustomInstructions(_ text: String, forBundle bundle: String) {
        var ov = userApp(bundle)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        ov.customInstructions = trimmed.isEmpty ? nil : trimmed
        setApp(bundle, ov)
    }

    func clear() {
        lock.lock()
        apps.removeAll(); domains.removeAll(); resolvedCache.removeAll()
        try? FileManager.default.removeItem(at: OverrideStore.url)
        lock.unlock()
    }

    // MARK: - Domain helpers

    // Strip a leading "domain:" and lowercase; callers may pass either form.
    private func normalizeDomain(_ p: String) -> String {
        var s = p.lowercased().trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("domain:") { s = String(s.dropFirst("domain:".count)) }
        return s
    }

    // A host matches a pattern when the pattern is a suffix on a label boundary
    // (e.g. "google.com" matches "docs.google.com" but not "notgoogle.com").
    private func hostMatches(_ host: String, pattern: String) -> Bool {
        let h = host.lowercased(), p = pattern.lowercased()
        if h == p { return true }
        return h.hasSuffix("." + p)
    }
}
