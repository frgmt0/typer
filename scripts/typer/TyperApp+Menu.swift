import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import SwiftUI
import Vision

// Single 1 Hz ticker driving the snooze countdown in the menu-bar title and pruning expired
// deadlines. Stored module-side because TyperApp's stored props live in TyperApp.swift (owned by
// another wave) and Swift extensions can't add stored properties; the app delegate is a singleton
// so a file-private holder is unambiguous. Only runs while a deadline is active, and self-stops.
private var snoozeCountdownTimer: Timer?

extension TyperApp {
    func setupMenu() {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        let pop = NSPopover()
        pop.behavior = .transient           // dismiss on click-away
        pop.animates = true
        let host = NSHostingController(rootView: MenuRootView(model: menuModel))
        host.sizingOptions = [.preferredContentSize]   // popover sizes to the SwiftUI content
        pop.contentViewController = host
        popover = pop
        updateStatusTitle()
    }

    // The menu-bar badge: a keyboard icon (renders reliably; a text-only status item
    // can collapse to zero width / be impossible to spot) plus the running count of
    // completions taken.
    func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        if button.image == nil {
            let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Typer")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
        }
        // An active snooze takes precedence over the running count: show "⏸ 14m" so the
        // pause and its remaining time are visible at a glance. updateStatusTitle is the
        // single place the title is computed, so the snooze countdown and the accept count
        // never fight over it.
        if cfg.enabled, let remaining = activeSnoozeRemaining() {
            button.title = " ⏸ \(Self.formatSnoozeRemaining(remaining))"
        } else {
            button.title = cfg.enabled ? " \(stats.accepted)" : " ⏸"
        }
    }

    // The largest live snooze deadline (global or any per-app), as seconds remaining, or nil
    // when nothing is snoozed. Prunes deadlines that have already passed so the map can't grow
    // unbounded. The displayed countdown is the soonest-to-expire active deadline so the badge
    // reflects "the snooze that will lift next."
    func activeSnoozeRemaining() -> TimeInterval? {
        let now = Date()
        var soonest: Date?
        if let g = allCompletionsDisabledUntil {
            if g > now { soonest = g } else { allCompletionsDisabledUntil = nil }
        }
        for (bundle, deadline) in perAppDisabledUntil {
            if deadline <= now { perAppDisabledUntil[bundle] = nil; continue }
            if soonest == nil || deadline < soonest! { soonest = deadline }
        }
        guard let s = soonest else { return nil }
        return s.timeIntervalSince(now)
    }

    // Round the remaining interval to a compact menu-bar label: "14m" above a minute, "45s"
    // below, ceiling-rounded so a snooze never reads "0m" while still active.
    static func formatSnoozeRemaining(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            let mins = Int((seconds / 60).rounded(.up))
            return "\(mins)m"
        }
        let secs = max(1, Int(seconds.rounded(.up)))
        return "\(secs)s"
    }

    // Start (or keep alive) the 1 Hz ticker that refreshes the snooze countdown badge and clears
    // expired deadlines. Idempotent; self-stops once no deadline remains so it costs nothing when
    // the user isn't snoozed.
    func startSnoozeCountdownIfNeeded() {
        guard activeSnoozeRemaining() != nil else { return }
        if snoozeCountdownTimer != nil { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); snoozeCountdownTimer = nil; return }
            // activeSnoozeRemaining prunes expired deadlines as a side effect.
            if self.activeSnoozeRemaining() == nil {
                timer.invalidate()
                snoozeCountdownTimer = nil
            }
            self.updateStatusTitle()
            self.menuModel.refresh()
        }
        // Fire during menu-tracking / modal run loops too, so the badge keeps counting down.
        RunLoop.main.add(t, forMode: .common)
        snoozeCountdownTimer = t
    }

    // Remaining seconds for the currently-targeted app's snooze, if any (for the menu UI).
    func appSnoozeRemaining(bundle: String) -> TimeInterval? {
        guard let d = perAppDisabledUntil[bundle] else { return nil }
        let r = d.timeIntervalSinceNow
        return r > 0 ? r : nil
    }

    // Remaining seconds for the global snooze, if any (for the menu UI).
    func globalSnoozeRemaining() -> TimeInterval? {
        guard let d = allCompletionsDisabledUntil else { return nil }
        let r = d.timeIntervalSinceNow
        return r > 0 ? r : nil
    }

    // Open/close the custom popover under the status item, snapshotting fresh state first.
    @objc func togglePopover(_ sender: Any?) {
        guard let pop = popover, let button = statusItem?.button else { return }
        if pop.isShown { pop.performClose(sender); return }
        // Capture the app you were actually in BEFORE activating Typer — otherwise the
        // "Disable in <app>" row would target Typer itself.
        popoverTargetAppKey = activeAppKey
        menuModel.refresh()
        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // The app the popover should act on for "Disable in <app>": the one captured at open time,
    // never Typer itself.
    func popoverTargetBundleAndName() -> (bundle: String, name: String) {
        let key = popoverTargetAppKey.isEmpty ? activeAppKey : popoverTargetAppKey
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        let bundle = parts.first ?? ""
        if bundle == "local.typer.menubar" { return ("", "") }   // don't offer to disable ourselves
        return (bundle, parts.count > 1 ? parts[1] : bundle)
    }

    // Snapshot everything the popover renders. The app stays the source of truth; the UI
    // just reads this on open and writes back through setToggle / performMenuAction.
    func menuSnapshot() -> MenuSnapshot {
        var s = MenuSnapshot()
        s.enabled = cfg.enabled
        s.completionEnabled = cfg.completionEnabled
        s.typoEnabled = cfg.typoEnabled
        s.grammarEnabled = cfg.grammarEnabled

        let (curBundle, curName) = popoverTargetBundleAndName()
        if !curBundle.isEmpty, curBundle != "no.bundle" {
            s.hasCurrentApp = true; s.currentAppName = curName
            s.currentAppDisabled = cfg.disabledApps.contains(curBundle)
        }
        s.disableInTerminals = cfg.disableInTerminals
        s.batterySaver = cfg.batterySaver
        s.batteryThrottling = cfg.batterySaver && PowerState.shared.saving

        s.windowContext = cfg.windowContextEnabled
        s.clipboardContext = cfg.clipboardContextEnabled
        s.screenContext = cfg.screenContextEnabled
        s.screenshotCaret = cfg.screenshotCaretEnabled
        s.topicMemory = cfg.topicMemoryEnabled; s.topicCount = topicMemory.count()
        s.styleMemory = cfg.styleMemoryEnabled
        s.lexicon = cfg.lexiconEnabled
        s.adaptive = cfg.adaptiveSuggestions

        s.trainingEnabled = cfg.trainingLogEnabled; s.trainingCount = trainingLog.count()

        // Snooze (#3): surface any active global / per-app deadline so the menu can show a
        // countdown and a Resume action instead of the snooze durations.
        if let g = globalSnoozeRemaining() {
            s.globalSnoozeActive = true
            s.globalSnoozeLabel = TyperApp.formatSnoozeRemaining(g)
        }
        if !curBundle.isEmpty, curBundle != "no.bundle", let a = appSnoozeRemaining(bundle: curBundle) {
            s.appSnoozeActive = true
            s.appSnoozeLabel = TyperApp.formatSnoozeRemaining(a)
        }
        s.anySnoozeActive = s.globalSnoozeActive || s.appSnoozeActive

        if let r = router?.raceState() {
            s.racing = true; s.aName = r.a; s.bName = r.b; s.aShare = r.aShare
            s.aReward = r.aReward; s.bReward = r.bReward; s.lockedName = r.lockedName
        } else if let r = router {
            s.singleModel = (r.nameA as NSString).deletingPathExtension
        }

        let w = stats.wordsCompleted, m = w / 40
        if w > 0 {
            s.statsLine1 = "\(numberFormatted(w)) words completed" + (m >= 1 ? " · ~\(numberFormatted(m)) min saved" : "")
        } else {
            s.statsLine1 = "No completions yet — start typing"
        }
        var l2 = "\(stats.acceptRate)% accepted · \(numberFormatted(lexicon.wordCount())) words learned"
        if stats.currentStreak > 0 { l2 = "\(stats.currentStreak)-day streak · " + l2 }
        s.statsLine2 = l2

        // Self-update is only offered for source builds that know where their checkout is
        // (stamped into Info.plist by build.sh) and still have an update.sh there to run.
        let commit = Bundle.main.object(forInfoDictionaryKey: "TyperGitCommit") as? String ?? ""
        s.version = commit.isEmpty ? "" : "#" + commit
        if let repo = Bundle.main.object(forInfoDictionaryKey: "TyperRepoPath") as? String, !repo.isEmpty {
            s.canUpdate = FileManager.default.fileExists(atPath: repo + "/update.sh")
        }

        s.modelVariant = effectiveVariant()
        return s
    }

    // Apply one toggle from the popover (mirrors the old NSMenu toggleSetting, minus the
    // NSMenuItem). Training capture still shows its one-time consent sheet before enabling.
    func setToggle(key: String, on v: Bool) {
        switch key {
        case "enabled": cfg.enabled = v; if !v { clearSuggestion() }
        case "completion_enabled": cfg.completionEnabled = v
        case "typo_correction_enabled": cfg.typoEnabled = v
        case "grammar_enabled": cfg.grammarEnabled = v
        // The popover binds this row but it previously had no case here, so it fell to
        // `default: return` and was a silent no-op. Wire it through like the others.
        case "disable_in_terminals": cfg.disableInTerminals = v; if isAppDisabled() { clearSuggestion() }
        case "window_context_enabled": cfg.windowContextEnabled = v
        case "clipboard_context_enabled": cfg.clipboardContextEnabled = v
        case "screen_context_enabled": cfg.screenContextEnabled = v
        case "screenshot_caret_enabled": cfg.screenshotCaretEnabled = v
        case "style_memory_enabled": cfg.styleMemoryEnabled = v
        case "lexicon_enabled": cfg.lexiconEnabled = v
        case "adaptive_suggestions": cfg.adaptiveSuggestions = v
        case "training_log_enabled":
            if v, !confirmTrainingCapture() { return }   // user backed out → leave off
            cfg.trainingLogEnabled = v
        case "battery_saver": cfg.batterySaver = v
        case "topic_memory_enabled":
            cfg.topicMemoryEnabled = v
            if v, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            startTopicTimer()
        // These two bind live Settings switches; without a case they fell to `default: return`,
        // never persisted, and the SwiftUI toggle visibly bounced back (review M2).
        case "show_suggested_fixes": cfg.showSuggestedFixes = v
        case "suppress_completion_on_typo_suspected": cfg.suppressCompletionOnTypoSuspected = v
        default: return
        }
        writeConfig(key, v ? "true" : "false")
        log("toggle \(key)=\(v)")
        updateStatusTitle()
    }

    // Sibling setters to setToggle for the non-Bool config rows the settings window edits.
    // Each updates cfg and persists the single key to config.toml. Wave 2A consumes these
    // from SettingsModel; W0 wires every key the spec's settings controls reference.
    func setInt(key: String, value: Int) {
        switch key {
        case "max_completion_words": cfg.maxCompletionWords = max(1, value)
        case "min_context_chars": cfg.minContextChars = max(0, value)
        case "emoji_skin_tone": cfg.emojiSkinTone = min(max(value, 0), 5)
        case "debounce_ms": cfg.debounceMs = max(0, value)
        case "idle_reset_seconds": cfg.idleResetSeconds = max(1, value)
        default: return
        }
        writeConfig(key, String(value))
        log("set \(key)=\(value)")
    }

    func setDouble(key: String, value: Double) {
        switch key {
        case "personalization_strength": cfg.personalizationStrength = min(max(value, 0), 1)
        case "min_confidence": cfg.minConfidence = max(0, value)
        case "topic_capture_seconds": cfg.topicCaptureSeconds = max(60, value)
        case "background_refresh_seconds": cfg.backgroundRefreshSeconds = max(0.5, value)
        default: return
        }
        writeConfig(key, String(value))
        log("set \(key)=\(value)")
    }

    func setString(key: String, value: String) {
        switch key {
        case "model_path": cfg.modelPath = (value as NSString).expandingTildeInPath
        default: return
        }
        writeConfig(key, value)
        log("set \(key)=<string>")
    }

    // MARK: - Timed snooze (#3) — Wave 2A fills the menu UI + countdown; these are the
    // action handlers behind the new MenuAction cases so the menu compiles in W0.

    func openSettingsFromMenu() { openSettings() }

    // Snooze ALL completions for `minutes`. Ephemeral deadline; clearSuggestion so any
    // visible ghost goes away immediately.
    func snoozeAll(minutes: Int) {
        allCompletionsDisabledUntil = Date().addingTimeInterval(Double(minutes) * 60)
        clearSuggestion()
        startSnoozeCountdownIfNeeded()
        updateStatusTitle()
        log("snooze all \(minutes)m")
    }

    // Snooze completions for the currently-targeted app only.
    func snoozeCurrentApp(minutes: Int) {
        let (bundle, _) = popoverTargetBundleAndName()
        guard !bundle.isEmpty, bundle != "no.bundle" else { return }
        perAppDisabledUntil[bundle] = Date().addingTimeInterval(Double(minutes) * 60)
        if isAppDisabled() || !completionsAllowed(bundle: bundle) { clearSuggestion() }
        startSnoozeCountdownIfNeeded()
        updateStatusTitle()
        log("snooze app \(bundle) \(minutes)m")
    }

    // Clear all snooze deadlines (global + per-app), stop the countdown ticker, and restore
    // the normal status title.
    func resumeCompletions() {
        allCompletionsDisabledUntil = nil
        perAppDisabledUntil.removeAll()
        snoozeCountdownTimer?.invalidate()
        snoozeCountdownTimer = nil
        updateStatusTitle()
        log("resumed completions")
    }

    // Route a popover button to its handler. Everything but the per-app toggle closes the
    // popover first so any file/sheet it opens isn't stuck behind it.
    func performMenuAction(_ a: MenuAction) {
        // The snooze rows and per-app toggle keep the popover open; everything else closes it
        // first so any file/sheet/window it opens isn't stuck behind the popover.
        switch a {
        case .disableCurrentApp, .snooze, .snoozeApp, .resumeCompletions: break
        default: popover?.performClose(nil)
        }
        switch a {
        case .config: openConfig()
        case .log: openLog()
        case .inspectTraining: openTrainingData()
        case .resetRace: resetRollout()
        case .clearStyle: clearStyle()
        case .resetAll: resetData()
        case .quit: quit()
        case .disableCurrentApp: toggleDisableCurrentApp()
        case .checkUpdates: checkForUpdates()
        case .openSettings: openSettingsFromMenu()
        case .snooze(let minutes): snoozeAll(minutes: minutes)
        case .snoozeApp(let minutes): snoozeCurrentApp(minutes: minutes)
        case .resumeCompletions: resumeCompletions()
        }
    }

    func configURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/config.toml")
    }

    // Persist a single key=value into config.toml (replacing the line or appending).
    func writeConfig(_ key: String, _ value: String) {
        let url = configURL()
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found = false
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key), t.dropFirst(key.count).trimmingCharacters(in: .whitespaces).first == "=" {
                lines[i] = "\(key) = \(value)"; found = true; break
            }
        }
        if !found { lines.append("\(key) = \(value)") }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @objc func openConfig() { NSWorkspace.shared.open(configURL()) }
    @objc func openLog() { NSWorkspace.shared.open(typerLogURL) }

    @objc func openTrainingData() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/training.jsonl")
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    // One-time explanation shown before training capture is enabled. Spells out exactly
    // what is stored, that it never leaves the Mac, the secret-skipping safeguards, and
    // how to inspect or erase it — the consent step the data's sensitivity warrants.
    func confirmTrainingCapture() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Record your typing to train a local model?"
        alert.informativeText = """
        Typer will save the text right before your cursor and each suggestion (plus whether you used it) to a file on THIS Mac — ~/Library/Application Support/typer/training.jsonl. It never leaves your computer; it exists only to train a local autocomplete model.

        What you type can include private things, so capture is skipped in password fields, password managers, and disabled apps, and any line that looks like a password, code, key, path, or email is dropped automatically. You can inspect the file, turn this off anytime, or erase it with “Reset All Data.”
        """
        alert.addButton(withTitle: "Record Locally")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Reconcile after the settings window edits cfg.disabledApps directly (it writes the config
    // itself): drop any visible ghost if the current app just became disabled, refresh the badge.
    func applyDisabledAppsChange() {
        if isAppDisabled() { clearSuggestion() }
        updateStatusTitle()
    }

    @objc func toggleDisableCurrentApp() {
        let (bundle, _) = popoverTargetBundleAndName()
        guard !bundle.isEmpty, bundle != "no.bundle" else { return }
        if cfg.disabledApps.contains(bundle) { cfg.disabledApps.remove(bundle) } else { cfg.disabledApps.insert(bundle) }
        writeConfig("disabled_apps", cfg.disabledApps.sorted().joined(separator: ","))
        if isAppDisabled() { clearSuggestion() }
        updateStatusTitle()
    }

    @objc func resetData() {
        let alert = NSAlert()
        alert.messageText = "Reset all Typer data?"
        alert.informativeText = "Clears your learned writing style, vocabulary, suggestion feedback, remembered on-screen topics, saved training data, and all stats, returning Typer to a fresh state. Your settings are kept. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        styleMemory.clear()
        topicMemory.clear()
        lexicon.clear()
        feedback.clear()
        router.reset()
        trainingLog.clear()
        OverrideStore.shared.clear()     // per-app/domain quirk + custom-instruction sidecar
        Admissibility.shared.reset()     // per-app capture backoff state
        InlinePrediction.clearRecord()   // forget the saved prior NSAutomaticInlinePrediction value (review L4)
        stats = TyperStats(); stats.save()
        buffer = ""; typedSinceNav = ""; buffersByApp.removeAll(); lastInputByApp.removeAll()
        // Every index that points into a per-app buffer has to go with the buffers. Leaving
        // `unlearnableSpans` behind was silent, permanent damage: the spans described text
        // that no longer existed, so `LearnableSpans.verified` returned nil on every flush
        // from then on and learning simply stopped — for good, with no way to tell.
        lexiconWatermark.removeAll()
        styleWatermark.removeAll()
        unlearnableSpans.removeAll()
        cachedBackground = ""; lastTrailing = ""; lastPresentedTail = ""; lastRejected = nil
        clearSuggestion()
        updateStatusTitle()
        log("user reset all data")
    }

    @objc func clearStyle() {
        styleMemory.clear()
        log("cleared learned style")
        updateStatusTitle()
    }

    // Restart typer-1's progressive rollout from the starting share (keeps the model,
    // forgets its accumulated accept/reject history and earned share).
    @objc func resetRollout() {
        router.reset()
        log("reset model race")
        updateStatusTitle()
    }

    @objc func quit() { stats.save(); NSApp.terminate(nil) }

    // MARK: - Self-update
    //
    // The app can't ship pre-signed (no Developer ID), so updates work by rebuilding from the
    // source checkout: build.sh stamps the repo path into Info.plist, and this drives update.sh
    // there. "Check for updates" fetches and counts commits behind upstream; if any, confirming
    // spawns a detached update.sh that fast-forwards, rebuilds (which kills this app), and
    // relaunches the new build. Progress lands in ~/Library/Logs/Typer-update.log.

    var updateLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Typer-update.log")
    }

    // The stamped source checkout, if this is a source build whose update.sh still exists.
    private func updateRepoPath() -> String? {
        guard let repo = Bundle.main.object(forInfoDictionaryKey: "TyperRepoPath") as? String,
              !repo.isEmpty,
              FileManager.default.fileExists(atPath: repo + "/update.sh") else { return nil }
        return repo
    }

    @objc func checkForUpdates() {
        guard !updateInProgress else { return }
        guard let repo = updateRepoPath() else {
            updateAlert(title: "Updates unavailable",
                        text: "This Typer build can't find its source checkout, so it can't update itself. Re-run install.sh (or scripts/build.sh) from the cloned repository to enable in-app updates.")
            return
        }
        updateInProgress = true
        log("checking for updates in \(repo)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // update.sh --check fetches and prints just the commits-behind count on stdout.
            let result = TyperApp.runUpdateScript(repo: repo, args: ["--check"], collectStdout: true)
            let behind = Int((result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateInProgress = false
                guard result.ok, let behind else {
                    self.updateAlert(title: "Couldn’t check for updates",
                                     text: "Failed to reach the Typer repository. Check your network connection and that the checkout at \(repo) is intact.")
                    return
                }
                if behind == 0 {
                    self.updateAlert(title: "Typer is up to date", text: "You’re on the latest version.")
                } else {
                    self.promptInstallUpdate(repo: repo, behind: behind)
                }
            }
        }
    }

    private func promptInstallUpdate(repo: String, behind: Int) {
        let plural = behind == 1 ? "" : "s"
        let alert = NSAlert()
        alert.messageText = "\(behind) update\(plural) available"
        alert.informativeText = """
        Typer is \(behind) commit\(plural) behind. It will download the latest changes, rebuild itself, and restart automatically — this takes about a minute and runs in the background.

        Progress is written to ~/Library/Logs/Typer-update.log.
        """
        alert.addButton(withTitle: "Update & Restart")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        startUpdate(repo: repo)
    }

    private func startUpdate(repo: String) {
        // Fresh log for this run.
        FileManager.default.createFile(atPath: updateLogURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: updateLogURL) else {
            updateAlert(title: "Update failed", text: "Couldn’t open the update log for writing.")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [repo + "/update.sh"]
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        p.standardOutput = handle
        p.standardError = handle
        do {
            try p.run()
        } catch {
            try? handle.close()
            updateAlert(title: "Update failed", text: "Couldn’t start update.sh: \(error.localizedDescription)")
            return
        }
        // Don't wait: build.sh terminates this app near the end, and update.sh (a separate
        // process, not matched by build.sh's pkill) survives to rebuild and relaunch the app.
        updateInProgress = true
        log("update started in background; rebuilding (log: \(updateLogURL.path))")
        statusItem?.button?.title = " ↻"
    }

    // Run update.sh and, when asked, capture its stdout (the --check count). stderr carries
    // progress and is discarded so it can't fill a pipe buffer and stall the read.
    private static func runUpdateScript(repo: String, args: [String], collectStdout: Bool) -> (ok: Bool, stdout: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [repo + "/update.sh"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        let outPipe = Pipe()
        p.standardOutput = collectStdout ? outPipe : FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return (false, "")
        }
        let data = collectStdout ? outPipe.fileHandleForReading.readDataToEndOfFile() : Data()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    private func updateAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
