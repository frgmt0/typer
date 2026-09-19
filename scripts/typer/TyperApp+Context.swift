import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

extension TyperApp {
    // MARK: - Broader context (window scrollback, screen OCR, clipboard, style)

    // Walk the focused window's AX subtree collecting visible text. For chat apps
    // this captures the conversation above the input box; for editors, the document.
    func windowText(limit: Int) -> String {
        guard let element = focusedElement() else { return "" }
        _ = axBound(element)   // 50 ms messaging timeout (D.1): a wedged host can't stall the walk
        let root: AXUIElement
        if let r = axRead(element, kAXWindowAttribute as String), CFGetTypeID(r) == AXUIElementGetTypeID() {
            root = axBound(r as! AXUIElement)
        } else { root = element }

        var collected: [String] = []
        var seen = Set<String>()
        var budget = 6000
        func walk(_ el: AXUIElement, depth: Int) {
            if depth > 14 || budget <= 0 { return }
            for attr in [kAXValueAttribute as String, kAXTitleAttribute as String] {
                if let s = axString(el, attr) {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count >= 2, t.count <= 2000, !seen.contains(t), !isNumericChrome(t) {
                        seen.insert(t)
                        collected.append(t)
                        budget -= t.count
                    }
                }
            }
            if let kidsRef = axRead(el, kAXChildrenAttribute as String), let kids = kidsRef as? [AXUIElement] {
                for k in kids { if budget <= 0 { break }; walk(axBound(k), depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        // Text nearest the input (typically last in reading order) is most relevant.
        return String(collected.joined(separator: "\n").suffix(limit))
    }

    // Short labels that are just a number/percentage (zoom "100%", "12", "3.5k", a
    // progress readout). Harmless as UI, but as prompt context they teach the base model
    // to emit bare percentages — keep them out of both the AX walk and OCR.
    func isNumericChrome(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 12 else { return false }
        if !t.contains(where: { $0.isNumber }) { return false }
        let lettery = t.filter { $0.isLetter }.count
        return lettery <= 1 || t.hasSuffix("%")
    }

    func clipboardText(limit: Int, relevantTo context: String) -> String {
        let pb = NSPasteboard.general
        // Skip clipboard content password managers mark concealed/transient — never
        // feed a copied password/secret into the prompt or logs.
        let types = pb.types?.map { $0.rawValue } ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") {
            return ""
        }
        guard let s = pb.string(forType: .string) else { return "" }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8 else { return "" }
        // Relevance: only fold the clipboard into the prompt if it's a short snippet
        // OR shares a meaningful word with what the user is currently writing. Stops
        // unrelated copied blobs from steering completions.
        if t.count > 60 {
            let ctxWords = Set(context.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
            let shares = t.lowercased().split { !$0.isLetter }.map(String.init).contains { $0.count >= 4 && ctxWords.contains($0) }
            guard shares else { return "" }
        }
        return String(t.prefix(limit))
    }

    // Capture the frontmost app's largest on-screen window via ScreenCaptureKit
    // (the modern replacement for the now-unavailable CGWindowListCreateImage).
    // Returns the image plus the window's screen frame (Quartz, top-left global),
    // which is needed to map OCR coordinates back to the screen.
    // `frontPID` is snapshotted on the main thread by the caller (NSWorkspace is
    // main-thread-affine). A class box carries the Task's result across the
    // semaphore so there's no write-after-return race on a local var.
    final class CaptureBox { var value: (image: CGImage, frame: CGRect, title: String)? }
    // `clip` (global, top-left Quartz coords) captures only that sub-rect of the window
    // instead of the whole thing — used by the caret locator to grab a thin band around
    // the caret line, which cuts both the capture and the downstream OCR cost by ~10x.
    // `scale` downsamples the captured pixels (1.0 = native); Vision cost scales with
    // pixel count, so 0.5 is ~4x cheaper OCR with no accuracy loss for body text.
    // The returned `frame` is the region actually captured (global, top-left), so OCR
    // box coordinates always map back to the screen correctly.
    func captureFocusedWindow(frontPID: pid_t?, clip: CGRect? = nil, scale: CGFloat = 1.0)
        -> (image: CGImage, frame: CGRect, title: String)? {
        guard #available(macOS 14.0, *) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        let box = CaptureBox()
        Task {
            defer { sem.signal() }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            let windows = content.windows.filter {
                $0.isOnScreen && $0.frame.width > 80 && $0.frame.height > 40 &&
                $0.owningApplication?.processID == frontPID
            }
            guard let win = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let config = SCStreamConfiguration()
            config.showsCursor = false
            // Resolve the captured region (window-local for sourceRect, global for the
            // returned frame). A clip is intersected with the window; an empty/degenerate
            // intersection falls back to the whole window.
            var captured = win.frame
            if let clip {
                let local = clip.intersection(win.frame)
                if local.width >= 8, local.height >= 8 {
                    config.sourceRect = CGRect(x: local.minX - win.frame.minX, y: local.minY - win.frame.minY,
                                               width: local.width, height: local.height)
                    captured = local
                }
            }
            let s = max(0.25, min(1.0, scale))
            config.width = max(8, Int(captured.width * s))
            config.height = max(8, Int(captured.height * s))
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                box.value = (img, captured, win.title ?? "")
            }
        }
        // Only read box.value if the Task actually finished (semaphore = happens-after).
        return sem.wait(timeout: .now() + 1.5) == .success ? box.value : nil
    }

    // Context OCR (spec C.1). Instead of OCR-ing the whole window @0.5× (sidebars,
    // toolbars, the lot), crop to a caret-anchored band — the focused field plus ~6 lines
    // above it — and then filter Vision observations to the field's horizontal column.
    // This is the same machinery the caret locator already uses (focusedElementQuartzRect
    // + captureFocusedWindow(clip:)), reused for context: ~5–10× less Vision work and the
    // sidebar/toolbar noise removed. Falls back to the whole-window @0.5× capture when no
    // field rect is available (AX-hostile apps), preserving the old behavior there.
    // `fieldQuartz`/`primaryMaxY` are snapshotted on the main thread by the caller (AX +
    // NSScreen are main-affine); this runs off-main.
    func screenOCR(limit: Int, frontPID: pid_t?, fieldQuartz: CGRect? = nil) -> String {
        guard CGPreflightScreenCaptureAccess() else { return "" }
        var clip: CGRect? = nil
        var xRange: (lo: CGFloat, hi: CGFloat)? = nil
        if let field = fieldQuartz, field.width > 4, field.height > 4 {
            // ~6 lines above the field; clip is intersected with the window inside capture.
            clip = field.insetBy(dx: 0, dy: -field.height * 6)
        }
        // Caret band at scale 1.0 (already tiny) for crisp small text; the whole-window
        // fallback stays at 0.5× since it's large.
        let cap = captureFocusedWindow(frontPID: frontPID, clip: clip, scale: clip == nil ? 0.5 : 1.0)
        guard let cap, cap.image.width > 8, cap.image.height > 8 else {
            if let pid = frontPID, let app = NSRunningApplication(processIdentifier: pid),
               let b = app.bundleIdentifier { Admissibility.shared.noteFailure(bundle: b) }
            return ""
        }
        // Field's normalized X-range within the CAPTURED frame, so we can drop observations
        // that fall outside the field's column (port of performOCR(on:textFieldXRange:)).
        if let field = fieldQuartz, cap.frame.width > 1, field.width > 4 {
            let lo = (field.minX - cap.frame.minX) / cap.frame.width
            let hi = (field.maxX - cap.frame.minX) / cap.frame.width
            if hi > lo { xRange = (lo, hi) }
        }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate          // far fewer "8nd"/"htttsngtab" misreads
        req.usesLanguageCorrection = true
        req.minimumTextHeight = 0.012             // skip tiny UI chrome (badges, status counters)
        // Vision wastes cycles probing for scripts the user never writes; pin to en-US when
        // the user is monolingual-English so detection is faster and cleaner.
        if isLikelyMonolingualEnglish() { req.recognitionLanguages = ["en-US"] }
        let handler = VNImageRequestHandler(cgImage: cap.image, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results else { return "" }
        var lines: [String] = []
        for o in obs {
            // X-range column filter (with a 0.1 normalized margin for inset/padding).
            if let xr = xRange {
                let m = o.boundingBox.midX
                if m < xr.lo - 0.1 || m > xr.hi + 0.1 { continue }
            }
            guard let cand = o.topCandidates(1).first, cand.confidence >= 0.5 else { continue }
            if isLikelyText(cand.string) { lines.append(cand.string) }
        }
        return String(lines.joined(separator: "\n").suffix(limit))
    }

    // Whether the user writes essentially only English, so OCR/Vision can pin to en-US.
    // Conservative: derives from the system's preferred languages (no extra state). If the
    // top preferred language isn't English we leave Vision in auto-detect mode.
    func isLikelyMonolingualEnglish() -> Bool {
        guard let primary = Locale.preferredLanguages.first else { return false }
        return primary.hasPrefix("en")
    }

    // Heuristic gate to keep OCR garbage (UI chrome, misreads, glyph soup) out of the
    // prompt: require mostly letters/spaces, at least one real word, and reject lines
    // dominated by digits/percent signs (zoom "100%", counters, progress, prices) — that
    // numeric chrome is exactly what made completions spit out spurious percentages.
    func isLikelyText(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 4 else { return false }
        let letters = t.filter { $0.isLetter || $0.isWhitespace }.count
        guard Double(letters) / Double(t.count) >= 0.75 else { return false }
        if t.contains("%") { return false }   // a percentage anywhere reads as a stat/chrome line
        let digits = t.filter { $0.isNumber }.count
        if Double(digits) / Double(t.count) >= 0.2 { return false }
        return t.split(whereSeparator: { !$0.isLetter }).contains { $0.count >= 3 }
    }

    // Screenshot-based caret locator for apps that don't expose AXBoundsForRange
    // (Electron, terminals, custom editors). Captures the focused window, OCRs it,
    // finds where the user's most-recently-typed text ends on screen, and returns
    // the caret rect there. Slow (~150ms), so callers must throttle/cache it.
    // Focused element's global rect in Quartz (top-left origin) coords — the space
    // SCStreamConfiguration.sourceRect / CGEvent use. Read on the main thread (AX is
    // main-affine), so the caret locator can capture just this element's band.
    func focusedElementQuartzRect() -> CGRect? {
        guard let element = focusedElement() else { return nil }
        _ = axBound(element)   // bounded AX reads (D.1)
        guard let posValue = axRead(element, kAXPositionAttribute as String),
              let sizeValue = axRead(element, kAXSizeAttribute as String) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width > 4, size.height > 4 else { return nil }
        return CGRect(origin: point, size: size)
    }

    func screenshotCaretRect(needle: String, frontPID: pid_t?, clip: CGRect?, primaryMaxY: CGFloat) -> (rect: CGRect, charWidth: CGFloat)? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        // `needle`, `frontPID`, `clip` and `primaryMaxY` are all snapshotted on the main
        // thread by the caller — never read self.buffer / NSWorkspace / AX / NSScreen
        // here (off-main). The Quartz→AppKit flip uses the passed-in primaryMaxY for the
        // same reason (NSScreen is main-affine), so we don't call axRectToAppKit here.
        guard needle.count >= 3 else { return nil }
        // Capture only the caret band (clip): a ~10x smaller image than the old
        // full-window grab, so both the capture and the Vision pass are far cheaper.
        // Keep scale 1.0 here (the band is already tiny) so the typed-tail match stays
        // reliable; boundingBox is normalized, so the screen mapping is scale-agnostic.
        guard let cap = captureFocusedWindow(frontPID: frontPID, clip: clip, scale: 1.0), cap.image.width > 8 else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast              // matching a typed tail needs speed, not perfect glyphs
        req.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cap.image, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results else { return nil }

        // Find the observation that ends with our typed tail. Prefer the lowest one
        // on screen (largest 1-minY), since that's usually the active input line.
        var best: VNRecognizedTextObservation?
        var bestLen = 0
        var bestScore = -1.0
        for o in obs {
            guard let s = o.topCandidates(1).first?.string.lowercased() else { continue }
            let hit = s.hasSuffix(needle) || s.contains(needle) || needle.hasSuffix(s.suffix(min(s.count, 8)))
            if hit {
                let score = Double(1 - o.boundingBox.minY)   // lower on screen wins
                if score > bestScore { bestScore = score; best = o; bestLen = s.count }
            }
        }
        guard let match = best else { return nil }
        // boundingBox is normalized (origin bottom-left of the image). The caret is at
        // the trailing-right edge, on that line.
        let box = match.boundingBox
        let f = cap.frame
        let quartzX = f.minX + box.maxX * f.width
        let quartzTopY = f.minY + (1 - box.maxY) * f.height        // top of the text box, Quartz top-left
        let h = max(12, box.height * f.height)
        let charWidth = bestLen > 0 ? (box.width * f.width) / CGFloat(bestLen) : 9
        // Quartz top-left → AppKit bottom-left flip with the main-thread-snapshotted
        // primary height (same math as axRectToAppKit, but NSScreen-free off the main thread).
        let appkitY = primaryMaxY - quartzTopY - h
        return (CGRect(x: quartzX, y: appkitY, width: 1, height: h), charWidth)
    }

    // Refresh the cached background off the hot path. Throttled by time + app key, unless
    // `force` (an AX-event-driven refresh from the debounce, C.2) bypasses the time gate —
    // the user just paused after editing, which is precisely when fresh background helps.
    // Per-app admissibility backoff (C.5) skips apps that recently errored/returned empty.
    func refreshBackgroundIfNeeded(force: Bool = false) {
        // Never capture our own UI (Settings/onboarding/menu): AX-walking a SwiftUI
        // window builds its a11y graph synchronously on the main thread → beachball.
        if frontmostIsSelf { return }
        let key = activeAppKey
        let (bundle, _) = currentAppBundleAndName()
        // Skip apps inside their capture-backoff window (C.5) — don't hammer a misbehaving
        // host. The static denylists are enforced elsewhere; this is the self-healing one.
        if Admissibility.shared.isBackedOff(bundle: bundle) { return }
        // Refresh less often while saving power (fewer AX/screenshot wakeups).
        let interval = powerSaving ? max(cfg.backgroundRefreshSeconds, 10.0) : cfg.backgroundRefreshSeconds
        let fresh = Date().timeIntervalSince(backgroundRefreshedAt) < interval && key == backgroundKey
        if (fresh && !force) || backgroundRefreshing { return }
        backgroundRefreshing = true
        // Snapshot cfg flags + frontmost PID on main (cfg mutates on main; NSWorkspace
        // is main-affine).
        let wantWindow = cfg.windowContextEnabled
        let wantScreen = cfg.screenContextEnabled
        let wantClipboard = cfg.clipboardContextEnabled
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let recentText = String(buffer.suffix(300))   // for clipboard relevance
        // Field rect for the cropped context OCR (C.1) — read AX on main, use off-main.
        let fieldQuartz = wantScreen ? focusedElementQuartzRect() : nil
        backgroundQueue.async {
            var parts: [String] = []
            // Prefer clean AX text. Only fall back to (noisier) OCR when AX gives us
            // little — typically Electron apps. This keeps OCR misreads out of the
            // prompt whenever a reliable source exists.
            var windowChars = 0
            if wantWindow {
                let w = self.windowText(limit: 1000)
                if w.count > 40 { parts.append(w); windowChars = w.count }
            }
            if wantScreen, windowChars < 120 {
                let o = self.screenOCR(limit: 600, frontPID: frontPID, fieldQuartz: fieldQuartz)
                if o.count > 40 { parts.append(o) }
            }
            if wantClipboard {
                let c = self.clipboardText(limit: 200, relevantTo: recentText)
                if !c.isEmpty { parts.append("Clipboard: " + c) }
            }
            let bg = parts.joined(separator: "\n")
            // Admissibility bookkeeping (C.5): an empty capture in an app that wanted one is
            // a soft failure (back off); any text clears the backoff.
            if !bundle.isEmpty {
                if bg.isEmpty, (wantWindow || wantScreen) {
                    Admissibility.shared.noteFailure(bundle: bundle)
                } else if !bg.isEmpty {
                    Admissibility.shared.noteSuccess(bundle: bundle)
                }
            }
            DispatchQueue.main.async {
                self.cachedBackground = bg
                self.backgroundRefreshedAt = Date()
                self.backgroundKey = key
                self.backgroundRefreshing = false
                log("background refreshed key=\(key) chars=\(bg.count) force=\(force)")
            }
        }
    }

    // Cheap AX field metadata for the prompt (spec C.3). No screenshot: read the focused
    // field's placeholder / title / help / description, web DOM identity, and the page URL,
    // all bounded by the 50 ms messaging timeout. Surface as a single labeled line so the
    // model knows what KIND of field this is ("Search", "Message #general", a compose box
    // on gmail.com) — a strong, essentially free signal that mirrors Cotypist's
    // TextFieldProperties. Returns "" when nothing useful is exposed.
    func fieldMetadataBlock() -> String {
        guard let el = focusedElement() else { return "" }
        _ = axBound(el)
        // Field label: prefer an explicit placeholder, else title/description/help.
        var label = ""
        for attr in [kAXPlaceholderValueAttribute as String, kAXTitleAttribute as String,
                     kAXDescriptionAttribute as String, kAXHelpAttribute as String] {
            if let s = axString(el, attr) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 2, t.count <= 80, !isNumericChrome(t) { label = t; break }
            }
        }
        // Web element identity (Chromium/WebKit expose these) — distinguishes fields within
        // one web app (Gmail compose vs. Gmail search).
        if label.isEmpty {
            if let dom = axString(el, "AXDOMIdentifier") {
                let t = dom.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 2, t.count <= 60 { label = t }
            }
        }
        // Page host (W1A's caret module owns currentWebHost() -> String?; reuse it so the
        // field line carries the domain, e.g. "gmail.com", distinguishing web fields).
        let host = currentWebHost() ?? ""
        let appName = currentAppBundleAndName().name
        if label.isEmpty && host.isEmpty { return "" }
        var line = "Field"
        if !label.isEmpty { line += ": \(label)" }
        if !appName.isEmpty { line += " in \(appName)" }
        if !host.isEmpty { line += " — \(host)" }
        return line
    }

    // Ambient topic capture: periodically OCR the focused window, distill its salient
    // topics, and store them. Throttled by the timer (every topic_capture_seconds) and
    // single-flighted, so it stays cheap.
    func startTopicTimer() {
        topicTimer?.invalidate(); topicTimer = nil
        guard cfg.topicMemoryEnabled else { return }
        let period = max(60, cfg.topicCaptureSeconds)
        topicTimer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { [weak self] _ in self?.captureTopic() }
        // One capture shortly after enabling/launch so it doesn't feel inert.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.captureTopic() }
    }

    func captureTopic() {
        guard cfg.topicMemoryEnabled, !topicCapturing, cfg.enabled else { return }
        if IsSecureEventInputEnabled() || isAppDisabled() { return }     // never capture secrets / disabled apps
        // Topic memory is for content you read (sites, docs), not terminals — those are
        // noisy (code/logs) and sensitive, so always skip them regardless of the
        // terminal-completion setting.
        if TyperApp.terminalBundleIDs.contains(currentAppBundleAndName().bundle) { return }
        guard CGPreflightScreenCaptureAccess() else { return }
        if powerSaving { return }                                        // skip the screenshot+OCR burst on battery saver
        topicCapturing = true
        let appKey = activeAppKey
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        backgroundQueue.async {
            defer { DispatchQueue.main.async { self.topicCapturing = false } }
            guard let cap = self.captureFocusedWindow(frontPID: frontPID, scale: 0.5), cap.image.width > 8 else { return }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.minimumTextHeight = 0.012
            guard (try? VNImageRequestHandler(cgImage: cap.image, options: [:]).perform([req])) != nil,
                  let obs = req.results else { return }
            let text = obs.compactMap { o -> String? in
                guard let c = o.topCandidates(1).first, c.confidence >= 0.4 else { return nil }
                return c.string
            }.joined(separator: "\n")
            guard text.count >= 80 else { return }
            let (keys, note) = distillTopics(text: text, title: cap.title)
            guard !keys.isEmpty, !note.isEmpty else { return }
            let appName = appKey.split(separator: "|").last.map(String.init) ?? appKey
            self.topicMemory.record(TopicEntry(at: Date().timeIntervalSince1970, app: appName,
                                               title: cap.title, keys: keys, note: note))
            log("topic captured app=\(appName) keys=\(keys.count)")
        }
    }

    // Assemble the final prompt context. The immediate before-cursor text always
    // comes LAST so the base model continues it; style + background precede it to
    // bias tone and topic. Heavy background is only folded in when the field itself
    // is sparse (chat boxes), where it helps most and risks the least regression.
    func assembledContext(immediate: String) -> String {
        var blocks: [String] = []
        let (appBundle, appName) = currentAppBundleAndName()
        // Per-app custom instructions (#1, spec E §1). The user's per-app instruction text
        // (AppOverrides.customInstructions, resolved with domain rows for web) is injected
        // as the very FIRST block so it shapes tone for THIS app only and survives token
        // budgeting (highest priority). It is appended LAST among instruction sources so a
        // per-app rule can override a broader one. Placed in the prompt, never the training
        // target (spec G #2), so the base model isn't overfit to one app's voice. When the
        // text changes the prompt prefix bytes change here, so the helper's value-match KV
        // prefix reuse re-decodes from this point automatically — no separate flag needed.
        let instr = resolvedInstructions(bundle: appBundle)
        if !instr.isEmpty { blocks.append("Instructions: \(instr)") }
        if !appName.isEmpty { blocks.append("Writing app: \(appName)") }
        // Cheap AX field metadata (C.3): placeholder/title/url tell the model what kind of
        // field this is — a strong, near-free signal. Placed early as background, before the
        // user's live line.
        let fieldMeta = fieldMetadataBlock()
        if !fieldMeta.isEmpty { blocks.append(fieldMeta) }
        // Put ambient context before style, and the user's live text last. The base
        // model continues the final line; the earlier labeled blocks are background it
        // may consider for topic/tone, NOT content to tailor the completion to. Framed
        // as on-screen reference (and kept shorter) so a short live line doesn't get
        // overwhelmed and steered off into whatever happens to be on screen.
        if immediate.count < cfg.maxImmediateForBackground, !cachedBackground.isEmpty {
            blocks.append("(On screen now — background only, may not be relevant)\n" + String(cachedBackground.suffix(500)))
        }
        // Resurface a recently-viewed topic ONLY when the user is now typing about it
        // (a distinctive entity/keyword from it appears in their recent text).
        if cfg.topicMemoryEnabled, let note = topicMemory.relevant(to: String(immediate.suffix(220))) {
            blocks.append("Earlier relevant topic: \(note)")
        }
        if cfg.styleMemoryEnabled {
            // Cache the ranked sample for a few seconds: relevance doesn't need
            // keystroke granularity, ranking the whole corpus per keystroke costs
            // main-thread time, and a sample that reshuffles per request changes the
            // middle of the prompt — invalidating the helper's KV prefix cache that
            // the stable context windows exist to preserve.
            // Personalization (#10): scale the style-sample size with
            // `cfg.personalizationStrength` (0..1). Strength 0 (the default) keeps the
            // established baseline so the working style feature never regresses; higher
            // strength widens the sample (up to 1.5×) so the completion leans harder toward
            // how the user writes. The companion channel is `personalizedLexicon()` on the
            // completion side, which ships the words themselves.
            let baseChars = immediate.count < cfg.maxImmediateForBackground ? 360 : 160
            let maxChars = Int((Double(baseChars) * (1.0 + 0.5 * cfg.personalizationStrength)).rounded())
            if Date().timeIntervalSince(styleSampleAt) > 5 || styleSampleChars != maxChars {
                cachedStyleSample = styleMemory.sample(maxChars: maxChars, relevantTo: immediate, category: appCategory())
                styleSampleAt = Date()
                styleSampleChars = maxChars
            }
            let s = cachedStyleSample
            if s.split(separator: " ").count >= 4 { blocks.append("Examples of my recent writing style:\n" + s) }
        }
        // Token-space budgeting (C.4): the blocks above are highest→lowest priority. Measure
        // each via the helper's tokenizer (LRU-cached) and admit in order until the budget is
        // spent, with `immediate` (the live line) ALWAYS kept last so a long background block
        // can never crowd it out. The leader client serves the tokenizer; budgeting falls
        // back to a char estimate if the helper isn't up yet (degrades gracefully, never
        // blocks input). Budget leaves headroom for generation inside the helper's 1536 ctx.
        // Belt and braces on the way out. Everything above is screened at its own source
        // (AX text, OCR, clipboard, style memory, per-app instructions), but this is the
        // single string that reaches the model, and one control or private-use scalar in a
        // greedily-decoded prompt is enough to make the helper echo it forever. The helper
        // strips again on its side; neither gate is load-bearing alone.
        if let client = router?.client(for: .a) {
            return TextSanitizer.stripped(client.budgetedContext(blocks: blocks, immediate: immediate,
                                                                 tokenBudget: contextTokenBudget))
        }
        blocks.append(immediate)
        return TextSanitizer.stripped(blocks.count == 1 ? immediate : blocks.joined(separator: "\n\n"))
    }

    // Resolve the instruction text to inject for the current app (#1, spec E §1). Per-app
    // `customInstructions` (resolved with the matching web-domain row) take precedence; a
    // global instruction source would be appended FIRST so the per-app text can override
    // its tone. No global-instructions config field exists this wave (W0 added only the
    // per-app `customInstructions` sidecar), so today this returns the per-app text alone;
    // the join is kept as the seam for a future global field. Bounded so a long instruction
    // can't dominate the prompt budget.
    func resolvedInstructions(bundle: String) -> String {
        var parts: [String] = []
        // (seam) global instructions would go here, before the per-app text.
        if let perApp = OverrideStore.shared.resolved(bundle: bundle, host: currentWebHost()).customInstructions {
            let t = perApp.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append(t) }
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(joined.prefix(300))
    }

    // Token budget for the assembled prompt's context blocks (C.4). The helper runs a 1536
    // token context; reserve room for the generated continuation and the model's own
    // wrapping, so the assembled context is capped well under that.
    var contextTokenBudget: Int { 1100 }
}
