import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import SwiftUI
import Vision

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
        button.title = cfg.enabled ? " \(stats.accepted)" : " ⏸"
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
        s.largeInstalled = ModelRouter.largeModelInstalled()
        return s
    }

    // Apply one toggle from the popover (mirrors the old NSMenu toggleSetting, minus the
    // NSMenuItem). Training capture still shows its one-time consent sheet before enabling.
    func setToggle(key: String, on v: Bool) {
        switch key {
        case "enabled": cfg.enabled = v; if !v { clearSuggestion() }
        case "completion_enabled": cfg.completionEnabled = v
        case "typo_correction_enabled": cfg.typoEnabled = v
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
        default: return
        }
        writeConfig(key, v ? "true" : "false")
        log("toggle \(key)=\(v)")
        updateStatusTitle()
    }

    // Route a popover button to its handler. Everything but the per-app toggle closes the
    // popover first so any file/sheet it opens isn't stuck behind it.
    func performMenuAction(_ a: MenuAction) {
        if a != .disableCurrentApp { popover?.performClose(nil) }
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
        stats = TyperStats(); stats.save()
        buffer = ""; buffersByApp.removeAll(); lastInputByApp.removeAll()
        lexiconWatermark.removeAll()
        cachedBackground = ""; lastTrailing = ""
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
