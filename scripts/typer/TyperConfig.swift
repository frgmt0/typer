import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

struct TyperConfig {
    var enabled = true
    var completionEnabled = true
    var typoEnabled = false
    var modelPath = ""   // explicit .gguf path; empty = auto-pick first in Models dir
    var maxCompletionWords = 7
    var minContextChars = 6
    // Trailing debounce before a generation fires. Must be longer than the gap
    // between keystrokes (~80–200ms) so we generate once per *pause* rather than
    // once per *key* — at 25ms we fired a full model inference on nearly every
    // character, which is the main battery drain.
    var debounceMs = 110
    var idleResetSeconds = 20
    // Battery / energy.
    var prefetchEnabled = true    // speculatively fetch the next chunk (≈2× inference)
    var batterySaver = true       // throttle on battery / Low Power Mode
    var batteryDebounceMs = 300   // debounce used while battery-saving (prefetch off too)
    // Broader-context sources. All on-device. Each degrades gracefully if its data
    // is unavailable (e.g. AX-hostile apps, or Screen Recording not granted).
    var windowContextEnabled = true   // read surrounding text in the focused window via AX
    var styleMemoryEnabled = true     // bias completions toward the user's own recent writing
    var clipboardContextEnabled = true
    // Personalization & quality gate.
    var lexiconEnabled = true         // learn the user's vocabulary; bias sampling toward it
    var adaptiveSuggestions = true    // adapt suggestion length + gate strictness to accept history
    // Suggestions whose mean token probability falls below this are not shown at
    // all — "show less, but right" is most of what makes inline completion feel
    // intentional rather than random. 0 disables the gate. Default calibrated
    // empirically on gemma-3n: good completions measured 0.27–0.78, observed
    // garbage ("use a .") 0.20 — so 0.22 separates them with margin.
    var minConfidence = 0.22
    var screenContextEnabled = false  // screenshot OCR as prompt context — off by default (noisy)
    // Screenshot+OCR caret locator for apps with no AX/text-marker caret (terminals,
    // custom editors). OFF by default: a full ScreenCaptureKit capture + Vision OCR
    // per caret update is very battery-heavy (it ran on the Neural Engine every ~1.2s
    // while typing in a terminal). Native and Electron/WebKit apps don't need it.
    var screenshotCaretEnabled = false
    // Ambient "topic memory": periodically OCR the focused window, distill the salient
    // entities/topics (not raw text), and resurface them later only when you type about
    // one. Off by default (needs Screen Recording). topic_capture_seconds is the period.
    var topicMemoryEnabled = false
    var topicCaptureSeconds = 180.0
    var backgroundRefreshSeconds = 4.0
    var maxImmediateForBackground = 220 // only fold in background when the field itself is sparse
    var debugLogging = false            // when true, logs include typed text/snippets
    // Opt-in local capture of (context → suggestion, accepted?) examples to
    // ~/Library/Application Support/typer/training.jsonl — the seed corpus + reward
    // signal for training a local autocomplete model. OFF by default; never leaves the
    // machine; cleared by "Reset All Data". See TrainingLog.swift and training/.
    var trainingLogEnabled = false
    var disabledApps: Set<String> = []  // bundle IDs where Typer stays silent
    var disableInTerminals = false      // skip terminal apps entirely

    // Two-model race (ModelRouter). When two models whose filenames begin with
    // `typer1ModelGlob` sit in Models/ (e.g. typer-1-raw.gguf + typer-1-distill.gguf), the
    // router sends each suggestion to one of them — starting 50/50 — and shifts share toward
    // whichever earns the higher graded reward (Tab/backtick = 1.0, type-through = 0.25/word,
    // ignored = 0), locking the winner once it reaches 80%. Fewer than two such files → it
    // just serves the single model. `typer1RatchetStep` is the per-adjust share move and
    // `typer1RatchetMinSamples` the per-arm samples + cooldown before each move.
    var typer1Enabled = true
    var typer1ModelGlob = "typer-1-"    // filename prefix marking the small racing models
                                        // (trailing "-" so the large "typer-1l.gguf" is excluded)

    // Model size the user has chosen. "small" = the on-device 0.6B (typer-1, the race above);
    // "large" = the higher-quality ~1.2GB model (typer-1l.gguf), for machines with RAM to spare.
    // Large is served as a single model (no race). Switched live from the menu / onboarding.
    var modelVariant = "small"          // "small" | "large"
    // First-launch onboarding (permissions + model choice + intro) is shown until completed.
    var onboardingComplete = false
    var typer1RatchetStep = 0.05        // share moved toward the leading model per adjust
    var typer1RatchetMinSamples = 40    // per-arm resolutions + cooldown before each adjust
    // Legacy single-candidate-rollout knobs, still parsed for old configs but unused by the
    // race (start is fixed at 50/50, the lock threshold at 80%).
    var typer1ShareStart = 0.10
    var typer1ShareMin = 0.05
    var typer1ShareMax = 0.95
    var typer1RegressionMargin = 0.08

    static func load() -> TyperConfig {
        var cfg = TyperConfig()
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/config.toml")
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else { return cfg }
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch key {
            case "enabled": cfg.enabled = value == "true"
            case "completion_enabled": cfg.completionEnabled = value == "true"
            case "typo_correction_enabled": cfg.typoEnabled = value == "true"
            case "model_path": cfg.modelPath = (value as NSString).expandingTildeInPath
            case "max_completion_words": cfg.maxCompletionWords = Int(value) ?? cfg.maxCompletionWords
            case "min_context_chars": cfg.minContextChars = Int(value) ?? cfg.minContextChars
            case "debounce_ms": cfg.debounceMs = Int(value) ?? cfg.debounceMs
            case "idle_reset_seconds": cfg.idleResetSeconds = Int(value) ?? cfg.idleResetSeconds
            case "prefetch_enabled": cfg.prefetchEnabled = value == "true"
            case "battery_saver": cfg.batterySaver = value == "true"
            case "battery_debounce_ms": cfg.batteryDebounceMs = Int(value) ?? cfg.batteryDebounceMs
            case "window_context_enabled": cfg.windowContextEnabled = value == "true"
            case "style_memory_enabled": cfg.styleMemoryEnabled = value == "true"
            case "clipboard_context_enabled": cfg.clipboardContextEnabled = value == "true"
            case "lexicon_enabled": cfg.lexiconEnabled = value == "true"
            case "adaptive_suggestions": cfg.adaptiveSuggestions = value == "true"
            case "min_confidence": cfg.minConfidence = Double(value) ?? cfg.minConfidence
            case "screen_context_enabled": cfg.screenContextEnabled = value == "true"
            case "screenshot_caret_enabled": cfg.screenshotCaretEnabled = value == "true"
            case "topic_memory_enabled": cfg.topicMemoryEnabled = value == "true"
            case "topic_capture_seconds": cfg.topicCaptureSeconds = Double(value) ?? cfg.topicCaptureSeconds
            case "background_refresh_seconds": cfg.backgroundRefreshSeconds = Double(value) ?? cfg.backgroundRefreshSeconds
            case "debug_logging": cfg.debugLogging = value == "true"
            case "training_log_enabled": cfg.trainingLogEnabled = value == "true"
            case "disable_in_terminals": cfg.disableInTerminals = value == "true"
            case "typer1_enabled": cfg.typer1Enabled = value == "true"
            case "typer1_model_glob": cfg.typer1ModelGlob = value
            case "model_variant": cfg.modelVariant = (value == "large") ? "large" : "small"
            case "onboarding_complete": cfg.onboardingComplete = value == "true"
            case "typer1_share_start": cfg.typer1ShareStart = Double(value) ?? cfg.typer1ShareStart
            case "typer1_share_min": cfg.typer1ShareMin = Double(value) ?? cfg.typer1ShareMin
            case "typer1_share_max": cfg.typer1ShareMax = Double(value) ?? cfg.typer1ShareMax
            case "typer1_ratchet_step": cfg.typer1RatchetStep = Double(value) ?? cfg.typer1RatchetStep
            case "typer1_ratchet_min_samples": cfg.typer1RatchetMinSamples = Int(value) ?? cfg.typer1RatchetMinSamples
            case "typer1_regression_margin": cfg.typer1RegressionMargin = Double(value) ?? cfg.typer1RegressionMargin
            case "disabled_apps": cfg.disabledApps = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            default: break
            }
        }
        return cfg
    }
}
