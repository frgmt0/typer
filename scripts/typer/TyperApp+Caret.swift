import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Caret placement.
//
// ONE probe per re-anchor produces ONE `CaretFix`, or nil — and nil means DO NOT SHOW.
// Everything downstream (ghost font, panel height, ghostWidth's measuring font, the
// screenshot capture clip) reads that struct instead of going back to AX, which is what
// keeps a placement to ~5-6 synchronous round-trips instead of the 10-50 it used to cost.
//
// The rules (what a plausible caret rect is, which screen owns a point, how large the
// ghost font may be, how long a cached fix may be extrapolated) live in CaretGeometry as
// pure functions. This file is the AX I/O, the caches and the invalidation around them.
//
// Invariants:
//   * nil beats wrong. There is no "put it at 400,400" tier and no clamp-onto-main-screen
//     rescue: every tier may fail, and when they all do the ghost hides.
//   * rects are validated in AX SPACE, before the flip, so AX-space (0,0,w,h) garbage can
//     never be laundered into a top-left-of-the-primary-display placement.
//   * only .marker/.bounds/.line produce an authoritative fix; .click/.ocr are
//     extrapolated anchors and are never remembered as an app's winning ladder path.
//   * the ghost font is bounded by the MEASURED line height, never by whatever point size
//     the host app's attributed string claims.

// How the frontmost app exposes text geometry. Browsers and Electron shells answer
// AXTextMarker first (and need AXManualAccessibility before they answer anything at all);
// native AppKit and AX-speaking terminals answer AXBoundsForRange first.
enum CaretHostKind { case webLike, native }

// A hashable box for an AXUIElement, so caches can be keyed by the actual focused field
// rather than by its bundle id. A bare-bundle font cache is what let one 48pt Notion
// heading poison every field in the app for the rest of the session.
struct AXElementKey: Hashable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

// The host font as AX reported it, unscaled. The displayed size is re-derived against the
// current line height on every probe, so a cached font can never outlive its plausibility.
struct CachedHostFont {
    var font: NSFont
    var color: NSColor?
    var at: Date
}

// A per-element memo with the same 30s TTL the font cache uses.
struct CachedElementFlag {
    var value: Bool
    var at: Date
}

// How an app's AX is behaving. Strikes must be CONSECUTIVE and RECENT: an app that times
// out once, works for a minute and times out again is not wedged, and the old counter —
// which never aged — eventually put every long-lived app on the click/OCR tiers.
struct ProbeHealth {
    var strikes: Int
    var at: Date
}

// All mutable caret-subsystem state lives here (a stored-property holder) so it can be
// owned entirely by the caret files without adding stored properties to TyperApp
// (extensions cannot declare stored properties).
final class CaretState {
    static let shared = CaretState()
    private init() {}

    // Which AX rect API the app actually answers, so we don't pay a failing round-trip
    // probing the wrong one first. Only .marker/.bounds are ever stored here.
    var ladderPathByBundle: [String: CaretLadderPath] = [:]
    // Chromium/Electron/WebKit vs native, resolved once per bundle (the Electron probe
    // stats the app bundle).
    var hostKindByBundle: [String: CaretHostKind] = [:]
    // Host font + line height, keyed by the FOCUSED ELEMENT and cleared on every focus
    // change (TTL 30s as a backstop for apps that restyle a field in place).
    var fontByElement: [AXElementKey: CachedHostFont] = [:]
    var lineHeightByElement: [AXElementKey: CGFloat] = [:]
    // Does THIS element answer the WebKit text-marker attribute, i.e. is it web content
    // regardless of what its host app's bundle id says (Apple Mail's message body is a
    // WKWebView inside a native app). Same 30s TTL as the font cache.
    var webContentByElement: [AXElementKey: CachedElementFlag] = [:]
    // ScrollWheelMonitor (lazily started once).
    var scrollMonitor: ScrollMonitor?
    // Pids we've already enabled AXEnhancedUserInterface / AXManualAccessibility on — set
    // ONCE per app (review H2): re-asserting either on every re-anchor makes the host
    // rebuild its AX tree synchronously and stalls the main thread.
    var enhancedUIPids: Set<pid_t> = []
    var manualAccessibilityPids: Set<pid_t> = []
    // Doc HOSTS (docs.google.com, …) whose "enable accessibility" dialog was already
    // shown. Keyed by host rather than by bundle so the prompt isn't spent on the first
    // doc host the browser happens to visit, and deliberately in-memory only: the user may
    // not have acted on it (dismissed the alert, opened the wrong menu, changed their
    // mind), and a permanent mark would mean never telling them again. At most one prompt
    // per launch per doc host is quiet enough not to nag and still recoverable.
    var docsPromptedHosts: Set<String> = []
    // The focused window's web host, memoized per focus session: reading it costs several
    // AX reads plus link detection, and it cannot change without a focus change.
    var webHostMemo: (bundle: String, host: String?)?
    // Apps whose AX is wedged: two consecutive, recent probes that came back with an
    // actual AX timeout buy the app a cooldown during which we don't probe at all.
    var probeHealthByPid: [pid_t: ProbeHealth] = [:]
    var axHostileUntilByPid: [pid_t: Date] = [:]
    // Set by the probe's AX reads when one of them really returned kAXErrorCannotComplete
    // (the status AX reports for a messaging timeout). Reset at the top of every probe.
    var probeTimedOut = false
    // Probe coalescing + the one-shot trailing probe that closes each 16ms window.
    var lastProbeAt = Date.distantPast
    var trailingProbeScheduled = false
    // Throttle on the screenshot/OCR caret locator, so an invalidation burst cannot turn
    // into a burst of screenshots.
    var shotAttemptAt = Date.distantPast
    // Screen-parameter / space-change / app-termination observers, installed once.
    var geometryObserversInstalled = false
}

extension TyperApp {
    var caretState: CaretState { CaretState.shared }

    // The caret probe runs on the main thread in front of the user's keystrokes, so it
    // gets a tighter budget than the 50ms the rest of the AX code uses. Restored on the
    // focused element as the probe unwinds (the timeout is per element handle).
    static let caretProbeTimeout: Float = 0.025
    // At most one probe per main-loop tick, whoever asks (observer, 90/280ms timers,
    // scroll, streaming partials).
    static let caretProbeCoalesce: TimeInterval = 0.016
    static let axHostileCooldown: TimeInterval = 10
    // Browsers get AXManualAccessibility + marker-first. Electron is detected from the
    // app bundle instead of being enumerated here.
    static let webLikeBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.mozilla.firefox",
    ]

    // MARK: - The single probe

    // The one entry point for "where is the caret". Returns nil when we do not know —
    // callers must hide the ghost rather than place it somewhere plausible-looking.
    //
    // `allowBackwardFrom` carries the optimistic point the ghost is currently drawn at:
    // during a fast type-through the host app often reports its caret a frame late, and
    // snapping the ghost backwards over the word being typed is worse than being a few
    // pixels ahead. Only same-line backward moves are suppressed; a wrap still wins.
    //
    // `forceFresh` opts out of the 16ms coalescing window. Callers on the COMPLETION path
    // must not use it (that is what the window is for: a burst of notifications, timers and
    // scroll events must cost one probe, not twenty), but a one-shot path that has nothing
    // to retry with must: a correction is armed or dropped on the spot, so handing it a
    // coalesced nil silently throws the correction away, and the trailing probe only ever
    // re-places a live completion.
    @discardableResult
    func resolveCaret(allowBackwardFrom optimistic: NSPoint? = nil, forceFresh: Bool = false) -> CaretFix? {
        startScrollMonitor()
        installGeometryObservers()
        let now = Date()
        if !forceFresh, now.timeIntervalSince(caretState.lastProbeAt) < TyperApp.caretProbeCoalesce {
            scheduleTrailingProbe()
            return cachedCaretFix()
        }
        caretState.lastProbeAt = now
        let started = CFAbsoluteTimeGetCurrent()
        let fix = probeCaret(allowBackwardFrom: optimistic)
        if let fix { adopt(fix) }
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        if ms > 8 {
            dlog("[\(activeAppKey)] slow caret probe \(String(format: "%.1f", ms))ms path=\(fix?.path.rawValue ?? "none")")
        }
        return fix
    }

    // The cached fix, already forward-shifted by advanceGhost for whatever has been typed
    // since. nil once the extrapolation budget is spent: past 600ms / 40 chars / a line
    // change the cached point is a guess, and the ghost hides until a fresh fix lands.
    func cachedCaretFix() -> CaretFix? {
        guard var fix = lastCaretFix else { return nil }
        guard CaretGeometry.extrapolationWithinBudget(age: Date().timeIntervalSince(lastCaretFixAt),
                                                      chars: charsSinceCaretFix,
                                                      lineChanges: lineChangesSinceCaretFix) else { return nil }
        // Substituting the forward-shifted point makes this OUR prediction, not the rect
        // AX reported, so the fix stops being authoritative: the settle path in
        // TyperApp+Completion calibrates the per-app width EMA against an authoritative
        // point, and calibrating against advanceGhost's own output taught the model
        // nothing but its own bias.
        if let point = lastCaretPoint, point != fix.pointAppKit {
            fix.pointAppKit = point
            fix.extrapolated = true
        }
        return fix
    }

    private func adopt(_ fix: CaretFix) {
        lastCaretFix = fix
        lastCaretPoint = fix.pointAppKit
        lastCaretHeight = fix.lineHeight
        // Only a point AX actually reported refreshes the coasting budget. When the
        // backward-snap guard handed back the optimistic point the ghost is already drawn
        // at, adopting it as a fresh fix reset the age/char counters — so on a host whose
        // AX caret is permanently a frame behind (Electron) every probe renewed the budget
        // and the ghost coasted on a guess indefinitely instead of hiding.
        guard !fix.extrapolated else { return }
        lastCaretFixAt = fix.at
        charsSinceCaretFix = 0
        lineChangesSinceCaretFix = 0
        // An authoritative AX fix supersedes the screenshot cache.
        if fix.isAuthoritative { shotCaretPoint = nil }
    }

    // Requests that arrive inside a coalescing window are collapsed into a single probe
    // fired as the window closes, so a burst of AX notifications + timers + a scroll can
    // never turn into a burst of synchronous AX round-trips.
    private func scheduleTrailingProbe() {
        guard !caretState.trailingProbeScheduled else { return }
        caretState.trailingProbeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + TyperApp.caretProbeCoalesce) { [weak self] in
            guard let self else { return }
            self.caretState.trailingProbeScheduled = false
            if self.completion != nil { self.showCompletionRemainder(reanchor: true) }
        }
    }

    // MARK: - Probe internals

    private struct CaretProbeContext {
        let element: AXUIElement
        let selection: CFRange?
        let elementFrameAX: CGRect?
        let trustedLineHeight: CGFloat?
        let primaryMaxY: CGFloat
        let screens: [CGRect]
    }

    // A rect tier's answer: the 1pt caret rect in AppKit space, the display that owns it,
    // which tier produced it, and whether this element's line height just changed under us.
    private struct ProbedCaret {
        let caret: CGRect
        let screen: CGRect
        let path: CaretLadderPath
        let lineHeightChanged: Bool
    }

    private func probeCaret(allowBackwardFrom optimistic: NSPoint?) -> CaretFix? {
        let bundle = currentAppBundleAndName().bundle
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let now = Date()
        caretState.probeTimedOut = false
        let hostile = (caretState.axHostileUntilByPid[pid] ?? .distantPast) > now
        let screens = NSScreen.screens.map(\.frame)
        let primaryMaxY = CoordinateUtil.primaryMaxY()

        var element: AXUIElement?
        var elementKey: AXElementKey?
        var elementFrameAX: CGRect?
        var caretLocation: Int?
        var probed: ProbedCaret?
        var kind: CaretHostKind = .native

        if !hostile, !frontmostIsSelf, let focused = focusedElementForProbe() {
            element = focused
            elementKey = AXElementKey(focused)
            kind = hostKind(bundle: bundle, pid: pid)
            // Chromium/Electron shells expose nothing until an assistive client asks them
            // to build their AX tree. Without this, marker AND bounds both fail in Chrome,
            // Slack, Discord, VS Code, Notion… which is how those apps ended up on the
            // click/OCR tiers forever.
            if kind == .webLike { applyManualAccessibilityIfNeeded(pid: pid) }
            applyEnhancedUserInterfaceIfNeeded(bundle: bundle, pid: pid)

            let axStarted = CFAbsoluteTimeGetCurrent()
            let selection = selectedRange(focused)
            caretLocation = selection.map { $0.length > 0 ? $0.location + $0.length : $0.location }
            elementFrameAX = elementFrame(focused)
            let ctx = CaretProbeContext(element: focused,
                                        selection: selection,
                                        elementFrameAX: elementFrameAX,
                                        trustedLineHeight: elementKey.flatMap { caretState.lineHeightByElement[$0] },
                                        primaryMaxY: primaryMaxY,
                                        screens: screens)
            probed = probeAXRect(ctx, bundle: bundle, kind: kind)
            let elapsed = CFAbsoluteTimeGetCurrent() - axStarted
            noteProbeHealth(pid: pid, produced: probed != nil,
                            timedOut: caretState.probeTimedOut, elapsed: elapsed)
            // Hand the element back to the shared 50ms budget for the non-caret readers
            // (context capture, typo ranges) that share this handle's app.
            _ = axBound(focused)
            if probed == nil { maybePromptGoogleDocs(element: focused, bundle: bundle, kind: kind) }
        }

        let overrides = resolvedOverrides(bundle: bundle, kind: kind)
        let verticalOffset = CGFloat(overrides.verticalAlignmentOffset ?? 0)
        let adjustment = CGFloat(overrides.fontSizeAdjustmentFactor ?? 1)

        // 1-3. A validated AX rect: the only tiers that pin the caret exactly.
        if let probed {
            let lineHeight = probed.caret.height
            // Self-healing trusted line height: the validator ACCEPTS a rect that broke the
            // trusted window (the other checks already bound garbage), and the new value is
            // written back here exactly as a normal one is, so a heading style applied to a
            // live element re-teaches the window instead of locking the ghost out of it.
            if let elementKey {
                if probed.lineHeightChanged, let old = caretState.lineHeightByElement[elementKey] {
                    dlog("[\(activeAppKey)] caret line height \(old) -> \(lineHeight) (element restyled)")
                    // The cached font described the old style; re-read it against the new line.
                    caretState.fontByElement[elementKey] = nil
                }
                caretState.lineHeightByElement[elementKey] = lineHeight
            }
            let typography = ghostTypography(element: element, key: elementKey, caretLocation: caretLocation,
                                             lineHeight: CaretGeometry.typographyLineHeight(lineHeight),
                                             adjustment: adjustment)
            let probedPoint = NSPoint(x: probed.caret.minX + 2, y: probed.caret.minY + verticalOffset)
            let point = suppressBackwardSnap(probedPoint, optimistic: optimistic, lineHeight: lineHeight)
            dlog("[\(activeAppKey)] caret path=\(probed.path.rawValue) point=\(point) lineH=\(lineHeight) font=\(typography.font.fontName)@\(typography.font.pointSize)")
            return CaretFix(pointAppKit: point, lineHeight: lineHeight, font: typography.font,
                            color: typography.color, screenFrame: probed.screen,
                            elementFrameAX: elementFrameAX, path: probed.path, at: now,
                            extrapolated: point != probedPoint)
        }

        // No AX rect this tick: size the ghost from the last line height this element gave
        // us, else the clamped default. Never from a stale per-bundle font.
        let fallbackLineHeight = elementKey.flatMap { caretState.lineHeightByElement[$0] } ?? CaretGeometry.defaultLineHeight
        let typography = ghostTypography(element: nil, key: elementKey, caretLocation: nil,
                                         lineHeight: CaretGeometry.typographyLineHeight(fallbackLineHeight),
                                         adjustment: adjustment)

        // 4. Click anchor: a left-click IS a caret placement. Slide it right by the
        // measured width of what has been typed since. Budgeted in time, in characters,
        // and against the field's right edge (past that the text has soft-wrapped onto a
        // line we cannot see).
        if cfg.clickCaretEnabled, let anchor = clickCaretPoint, clickCaretApp == activeAppKey {
            let typedSince = String(buffer.suffix(max(0, buffer.count - clickCaretBufferLen)))
            let advance = typedSince.isEmpty ? 0 : ghostWidth(typedSince) * widthScale()
            // anchor.y is the click's vertical centre; drop half a line to the line bottom
            // the overlay renders from.
            let estimate = NSPoint(x: anchor.x + advance,
                                   y: anchor.y - fallbackLineHeight / 2 + verticalOffset)
            if CaretGeometry.clickAnchorUsable(age: now.timeIntervalSince(clickCaretAt),
                                               chars: typedSince.count,
                                               containsNewline: typedSince.contains { $0 == "\n" || $0 == "\r" },
                                               anchorX: anchor.x, advance: advance,
                                               elementMaxX: elementFrameAX?.maxX),
               let screen = CaretGeometry.screenContaining(point: estimate, in: screens) {
                let point = suppressBackwardSnap(estimate, optimistic: optimistic, lineHeight: fallbackLineHeight)
                dlog("[\(activeAppKey)] caret path=click point=\(point) lineH=\(fallbackLineHeight) font=\(typography.font.pointSize)")
                return CaretFix(pointAppKit: point, lineHeight: fallbackLineHeight, font: typography.font,
                                color: typography.color, screenFrame: screen,
                                elementFrameAX: elementFrameAX, path: .click, at: now,
                                extrapolated: point != estimate)
            }
        }

        // 5. Screenshot/OCR caret (GPU terminals, custom editors). Recomputed rarely and
        // extrapolated horizontally between captures.
        if cfg.screenshotCaretEnabled {
            refreshShotCaretIfNeeded()
            if let shot = shotCaretPoint, shotCaretApp == activeAppKey,
               now.timeIntervalSince(shotCaretAt) < 6 {
                let typedSince = max(0, buffer.count - shotCaretBufferLen)
                let point = NSPoint(x: shot.x + CGFloat(typedSince) * shotCaretCharWidth, y: shot.y + verticalOffset)
                if let screen = CaretGeometry.screenContaining(point: point, in: screens) {
                    let lineHeight = CaretGeometry.clamp(shotCaretHeight, CaretGeometry.minLineHeight, CaretGeometry.maxLineHeight)
                    let ocrType = ghostTypography(element: nil, key: elementKey, caretLocation: nil,
                                                  lineHeight: lineHeight, adjustment: adjustment)
                    dlog("[\(activeAppKey)] caret path=ocr point=\(point) lineH=\(lineHeight) font=\(ocrType.font.pointSize)")
                    return CaretFix(pointAppKit: point, lineHeight: lineHeight, font: ocrType.font,
                                    color: ocrType.color, screenFrame: screen,
                                    elementFrameAX: elementFrameAX, path: .ocr, at: now)
                }
            }
        }

        // 6. Nothing. The caller hides the ghost and keeps the suggestion text, so it
        // reappears the moment a real fix lands.
        dlog("[\(activeAppKey)] caret unresolved — hiding")
        return nil
    }

    // During a fast type-through the host's AX caret can lag our event tap by a frame. A
    // same-line backward report is that lag, not a cursor move (real moves arrive through
    // mouse-down/scroll invalidation, and a wrap changes y).
    private func suppressBackwardSnap(_ point: NSPoint, optimistic: NSPoint?, lineHeight: CGFloat) -> NSPoint {
        guard let optimistic,
              abs(point.y - optimistic.y) <= max(6, lineHeight * 0.65),
              point.x + 1 < optimistic.x else { return point }
        return optimistic
    }

    // MARK: - AX rect tiers

    private func probeAXRect(_ ctx: CaretProbeContext, bundle: String, kind: CaretHostKind) -> ProbedCaret? {
        var order: [CaretLadderPath] = kind == .webLike ? [.marker, .bounds] : [.bounds, .marker]
        if let preferred = caretState.ladderPathByBundle[bundle], order.contains(preferred) {
            order = [preferred] + order.filter { $0 != preferred }
        }
        for step in order {
            switch step {
            case .marker:
                if let hit = markerCaretRect(ctx) { rememberLadderPath(.marker, bundle: bundle); return hit }
            case .bounds:
                if let hit = boundsCaretRect(ctx) { rememberLadderPath(.bounds, bundle: bundle); return hit }
            default:
                break
            }
        }
        // Last AX resort: the caret's LINE rect. It only yields an x at the line's ends,
        // which is exactly the case that matters for apps whose AXSelectedTextRange is a
        // permanent {0,0} (GPU terminals) — and it is deliberately not a remembered path.
        return lineCaretRect(ctx)
    }

    // Caret rect via the WebKit/Chromium AXTextMarker attributes. These are private
    // string-named AX attributes (not in the public constants) but are read the same way;
    // the marker-range value is opaque and just passed straight through.
    private func markerCaretRect(_ ctx: CaretProbeContext) -> ProbedCaret? {
        guard let markerRange = caretAXRead(ctx.element, "AXSelectedTextMarkerRange"),
              let boundsRef = caretAXReadParam(ctx.element, "AXBoundsForTextMarkerRange", markerRange),
              CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        var rectAX = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rectAX) else { return nil }
        // A collapsed marker range is the caret and comes back ~zero-width. A wide answer
        // is the selection or the paragraph, and using it put the ghost at the start of a
        // block instead of at the caret.
        guard let valid = validate(rectAX, .collapsed, ctx) else { return nil }
        return probed(valid, atX: CaretGeometry.collapsedCaretX(in: valid.rectAppKit), path: .marker)
    }

    // AXBoundsForRange, at most THREE probes (the old 40-step back-scan cost up to 40
    // synchronous round-trips on the main thread for a rect whose x we then overrode).
    private func boundsCaretRect(_ ctx: CaretProbeContext) -> ProbedCaret? {
        guard let selection = ctx.selection else { return nil }
        // A non-collapsed selection is probed at its collapsed END; the selection rect
        // itself is never a caret.
        let location = selection.length > 0 ? selection.location + selection.length : selection.location
        guard location >= 0 else { return nil }
        // 1. The zero-length caret rect, when the app answers one. A block-cursor terminal
        // answers with the CELL the caret sits on instead of a hairline, so which edge is
        // the caret depends on the rect's width (CaretGeometry.collapsedCaretX).
        if let rect = axBoundsRect(ctx.element, CFRange(location: location, length: 0)),
           let valid = validate(rect, .collapsed, ctx) {
            return probed(valid, atX: CaretGeometry.collapsedCaretX(in: valid.rectAppKit), path: .bounds)
        }
        // 2. cursorRectIsFromPreviousCharacter: the right edge of the glyph before it.
        if location > 0,
           let rect = axBoundsRect(ctx.element, CFRange(location: location - 1, length: 1)),
           let valid = validate(rect, .glyph, ctx) {
            return probed(valid, atX: valid.rectAppKit.maxX, path: .bounds)
        }
        // 3. The left edge of the glyph after it.
        if let rect = axBoundsRect(ctx.element, CFRange(location: location, length: 1)),
           let valid = validate(rect, .glyph, ctx) {
            return probed(valid, atX: valid.rectAppKit.minX, path: .bounds)
        }
        return nil
    }

    // AXInsertionPointLineNumber + AXRangeForLine + AXBoundsForRange(line). A line rect
    // carries no caret column, so it is only usable at a line's ends: at the end (x =
    // maxX), on an empty line, or at the first index of a line that is not line 0 (a fresh
    // line — line 0 is also what a lying {0,0} app reports, so we don't trust that one).
    private func lineCaretRect(_ ctx: CaretProbeContext) -> ProbedCaret? {
        guard let selection = ctx.selection else { return nil }
        guard let lineRef = caretAXRead(ctx.element, kAXInsertionPointLineNumberAttribute as String),
              let line = lineRef as? Int, line >= 0 else { return nil }
        guard let rangeRef = caretAXReadParam(ctx.element, kAXRangeForLineParameterizedAttribute as String, NSNumber(value: line)),
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var lineRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &lineRange), lineRange.location >= 0 else { return nil }
        guard let rect = axBoundsRect(ctx.element, lineRange),
              let valid = validate(rect, .line, ctx) else { return nil }
        let location = selection.length > 0 ? selection.location + selection.length : selection.location
        let lineEnd = lineRange.location + lineRange.length
        let x: CGFloat
        if lineRange.length == 0 || (location == lineRange.location && line > 0) {
            x = valid.rectAppKit.minX
        } else if location >= lineEnd || endsWithNewline(ctx.element, lineRange: lineRange, caret: location) {
            // maxX is the line box's right edge. The trailing newline AXRangeForLine
            // includes has no advance width, so it does not inflate that edge — the rect
            // for "abc\n" ends where "abc" ends. (A host that did inflate it would push
            // the ghost right by one space, not place it on the wrong line.)
            x = valid.rectAppKit.maxX
        } else {
            return nil   // mid-line: the line rect says nothing about where the caret is
        }
        return probed(valid, atX: x, path: .line)
    }

    // AXRangeForLine reports the line INCLUDING its terminating newline, so on every line
    // but the last the caret at the visual end of the line sits at lineEnd - 1, not at
    // lineEnd — and the `location >= lineEnd` test above therefore failed on exactly the
    // case this tier exists for. One AXStringForRange read of a single character settles
    // it; it runs only in this last-resort tier, and only when the caret is one short of
    // the line's end.
    private func endsWithNewline(_ element: AXUIElement, lineRange: CFRange, caret: Int) -> Bool {
        let lineEnd = lineRange.location + lineRange.length
        guard lineRange.length > 0, caret == lineEnd - 1 else { return false }
        var last = CFRange(location: lineEnd - 1, length: 1)
        guard let param = AXValueCreate(.cfRange, &last),
              let value = caretAXReadParam(element, kAXStringForRangeParameterizedAttribute as String, param),
              let text = value as? String, let ch = text.unicodeScalars.first else { return false }
        return ch == "\n" || ch == "\r" || ch == "\u{2028}" || ch == "\u{2029}"
    }

    private func validate(_ rectAX: CGRect, _ kind: CaretProbeKind, _ ctx: CaretProbeContext)
        -> CaretGeometry.ValidatedCaretRect? {
        CaretGeometry.validateAXCaretRect(rectAX, kind: kind,
                                          elementFrameAX: ctx.elementFrameAX,
                                          trustedLineHeight: ctx.trustedLineHeight,
                                          primaryMaxY: ctx.primaryMaxY,
                                          screens: ctx.screens)
    }

    @inline(__always)
    private func probed(_ valid: CaretGeometry.ValidatedCaretRect, atX x: CGFloat,
                        path: CaretLadderPath) -> ProbedCaret {
        ProbedCaret(caret: CGRect(x: x, y: valid.rectAppKit.minY, width: 1, height: valid.rectAppKit.height),
                    screen: valid.screenFrame, path: path, lineHeightChanged: valid.lineHeightChanged)
    }

    private func rememberLadderPath(_ path: CaretLadderPath, bundle: String) {
        guard path == .marker || path == .bounds else { return }
        guard caretState.ladderPathByBundle[bundle] != path else { return }
        caretState.ladderPathByBundle[bundle] = path
        dlog("[\(activeAppKey)] caret path -> \(path.rawValue)")
    }

    // MARK: - Bounded AX reads used by the probe

    // A bounded AX read that also REPORTS a timeout. axRead() collapses every failure into
    // nil, and only `cannotComplete` — the status AX returns when the messaging timeout
    // expires or the target is unresponsive — says anything about the app's health.
    // Counting strikes by elapsed WALL TIME instead (the old rule) called a healthy app
    // hostile whenever our own main thread was descheduled for 25ms, and called a genuinely
    // missing attribute a timeout.
    @inline(__always)
    private func caretAXRead(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if status == .cannotComplete { caretState.probeTimedOut = true }
        return status == .success ? value : nil
    }

    @inline(__always)
    private func caretAXReadParam(_ element: AXUIElement, _ attribute: String, _ param: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, param, &value)
        if status == .cannotComplete { caretState.probeTimedOut = true }
        return status == .success ? value : nil
    }

    // The focused element, bound to the tighter caret-probe timeout.
    //
    // ONLY the focused element is re-bound. AXUIElementSetMessagingTimeout on a SYSTEM-WIDE
    // element is documented to set the timeout for the whole process, so doing it here set
    // a permanent process-global 25ms — never restored — that quietly overrode AXSafe's
    // 50ms budget for every other reader (context capture, typo ranges, the observer).
    // The element handle is handed back to axBound()'s 50ms as the probe unwinds.
    private func focusedElementForProbe() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        guard let value = caretAXRead(system, kAXFocusedUIElementAttribute as String),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, TyperApp.caretProbeTimeout)
        return element
    }

    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = caretAXRead(element, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        return range
    }

    // The focused element's frame in AX (top-left) space. Used to reject caret rects that
    // fall outside the field they claim to belong to, and as the screenshot capture clip.
    private func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let posValue = caretAXRead(element, kAXPositionAttribute as String),
              let sizeValue = caretAXRead(element, kAXSizeAttribute as String),
              CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              origin.x.isFinite, origin.y.isFinite, size.width > 4, size.height > 4 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func axBoundsRect(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var input = range
        guard let param = AXValueCreate(.cfRange, &input),
              let boundsValue = caretAXReadParam(element, kAXBoundsForRangeParameterizedAttribute as String, param),
              CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    // How long a strike stays on an app's record. Past this the app has demonstrably been
    // answering, so an old strike says nothing about the probe happening now.
    static let probeStrikeMaxAge: TimeInterval = 2

    // Two CONSECUTIVE and RECENT probes that came back with an actual AX timeout mean the
    // app's AX is wedged. Probing it again just stalls the main thread, so it goes on the
    // click/OCR tiers for a cooldown.
    //
    // Both qualifiers are the fix: strikes used to be counted whenever the probe merely
    // took longer than the timeout in wall-clock terms (a descheduled main thread, a
    // breakpoint, a busy machine — none of which is the app's fault), and they never aged,
    // so a strike from ten minutes ago could pair with one now and blind us to a perfectly
    // healthy app for 10s at a time.
    private func noteProbeHealth(pid: pid_t, produced: Bool, timedOut: Bool, elapsed: CFTimeInterval) {
        if produced {
            caretState.probeHealthByPid[pid] = nil
            return
        }
        guard timedOut else { return }
        let now = Date()
        let previous = caretState.probeHealthByPid[pid]
        let recent = previous.map { now.timeIntervalSince($0.at) <= TyperApp.probeStrikeMaxAge } ?? false
        let strikes = recent ? (previous?.strikes ?? 0) + 1 : 1
        caretState.probeHealthByPid[pid] = ProbeHealth(strikes: strikes, at: now)
        guard strikes >= 2 else { return }
        caretState.probeHealthByPid[pid] = nil
        caretState.axHostileUntilByPid[pid] = now.addingTimeInterval(TyperApp.axHostileCooldown)
        dlog("[\(activeAppKey)] AX-hostile pid=\(pid) after \(String(format: "%.0f", elapsed * 1000))ms — click/OCR only for \(Int(TyperApp.axHostileCooldown))s")
    }

    // MARK: - Ghost typography

    // Source order: the per-element cache, then the AX attributed string at the caret,
    // then a system font sized from the validated rect. An AX font is only believed (and
    // only cached) when its own line box matches the line we measured — the Notion H1 that
    // reports 48pt for an 18pt caret rect is describing the block, not the run.
    private func ghostTypography(element: AXUIElement?, key: AXElementKey?, caretLocation: Int?,
                                 lineHeight: CGFloat, adjustment: CGFloat) -> (font: NSFont, color: NSColor) {
        if let key, let cached = caretState.fontByElement[key], Date().timeIntervalSince(cached.at) < 30 {
            let sizing = CaretGeometry.ghostFontSizing(axFontPointSize: cached.font.pointSize,
                                                       axFontHeight: lineBoxHeight(cached.font),
                                                       lineHeight: lineHeight, adjustment: adjustment)
            if sizing.trusted {
                let font = NSFont(descriptor: cached.font.fontDescriptor, size: sizing.size) ?? NSFont.systemFont(ofSize: sizing.size)
                return (font, cached.color ?? NSColor.labelColor)
            }
            // The field restyled under us: stop trusting the cached font.
            caretState.fontByElement[key] = nil
        }
        if let element, let caretLocation, let read = focusedElementFont(element, at: caretLocation) {
            let sizing = CaretGeometry.ghostFontSizing(axFontPointSize: read.font.pointSize,
                                                       axFontHeight: lineBoxHeight(read.font),
                                                       lineHeight: lineHeight, adjustment: adjustment)
            if sizing.trusted {
                if let key { caretState.fontByElement[key] = CachedHostFont(font: read.font, color: read.color, at: Date()) }
                let font = NSFont(descriptor: read.font.fontDescriptor, size: sizing.size) ?? NSFont.systemFont(ofSize: sizing.size)
                return (font, read.color ?? NSColor.labelColor)
            }
            // Untrusted: never cached, and rendered in the system font at the clamped size.
            return (NSFont.systemFont(ofSize: sizing.size), read.color ?? NSColor.labelColor)
        }
        let sizing = CaretGeometry.ghostFontSizing(axFontPointSize: nil, axFontHeight: nil,
                                                   lineHeight: lineHeight, adjustment: adjustment)
        return (NSFont.systemFont(ofSize: sizing.size), NSColor.labelColor)
    }

    @inline(__always)
    private func lineBoxHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    // Read the focused element's REAL font + color for the caret char range, via the
    // AXAttributedStringForRange parameterized attribute.
    func focusedElementFont(_ element: AXUIElement, at location: Int) -> (font: NSFont, color: NSColor?)? {
        var range = CFRange(location: max(0, location), length: 1)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        guard let attrRef = axReadParam(element, kAXAttributedStringForRangeParameterizedAttribute as String, axRange),
              let string = attrRef as? NSAttributedString, string.length > 0 else { return nil }
        guard let font = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return nil }
        return (font, string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
    }

    // MARK: - Host classification and per-app AX opt-ins

    // Is the frontmost app a Chromium/Electron/WebKit shell? The typo/emoji apply paths
    // use this to choose between an AX text write and the keystroke fallback (those
    // shells acknowledge AX writes and then insert at the live caret anyway).
    var frontmostIsWebLike: Bool {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        return hostKind(bundle: currentAppBundleAndName().bundle, pid: pid) == .webLike
    }

    // Is THIS element web content, whatever its host app is?
    //
    // The per-bundle classification above answers "is the app a browser or an Electron
    // shell", and that is not the same question: Apple Mail, Notes, Xcode's docs, Slack's
    // native wrapper and any number of native apps host a WKWebView for one field. Those
    // apps classify as .native, so the typo/emoji apply path took the AX-write branch —
    // and a WebKit contenteditable acknowledges the write and then inserts at the live
    // caret anyway, which is the "this" -> "ththeis" corruption.
    //
    // AXSelectedTextMarkerRange is readable on WebKit/Chromium text elements and on
    // nothing else, so asking THE ELEMENT is the exact test. One AX read, memoized per
    // element for 30s (the same TTL and the same lifetime as the font cache: both are
    // dropped on every focus change), so the apply path pays it at most once per field.
    func elementIsWebContent(_ element: AXUIElement) -> Bool {
        let key = AXElementKey(element)
        let now = Date()
        if let cached = caretState.webContentByElement[key], now.timeIntervalSince(cached.at) < 30 {
            return cached.value
        }
        let isWeb = axRead(element, "AXSelectedTextMarkerRange") != nil
        caretState.webContentByElement[key] = CachedElementFlag(value: isWeb, at: now)
        return isWeb
    }

    // The question the typo / emoji apply paths actually want answered: may we replace text
    // in this element with an AX write, or must we use the keystroke path? Web content
    // anywhere — a whole browser or one embedded view — means keystrokes.
    func isWebContentElement(_ element: AXUIElement) -> Bool {
        frontmostIsWebLike || elementIsWebContent(element)
    }

    func hostKind(bundle: String, pid: pid_t) -> CaretHostKind {
        if let cached = caretState.hostKindByBundle[bundle] { return cached }
        var kind: CaretHostKind = .native
        if TyperApp.webLikeBundleIDs.contains(bundle) {
            kind = .webLike
        } else if pid > 0, let url = NSRunningApplication(processIdentifier: pid)?.bundleURL {
            // Every Electron shell embeds "Electron Framework.framework"; one stat per
            // bundle id is cheaper than maintaining a list of every Electron app shipped.
            let framework = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
            if FileManager.default.fileExists(atPath: framework.path) { kind = .webLike }
        }
        caretState.hostKindByBundle[bundle] = kind
        return kind
    }

    // Chromium/Electron build their AX tree lazily and only for a client that asks. Set
    // ONCE per pid: re-asserting it makes the renderer rebuild the tree synchronously.
    private func applyManualAccessibilityIfNeeded(pid: pid_t) {
        guard pid > 0, !caretState.manualAccessibilityPids.contains(pid) else { return }
        caretState.manualAccessibilityPids.insert(pid)
        AXUIElementSetAttributeValue(axAppElement(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        dlog("[\(activeAppKey)] AXManualAccessibility set pid=\(pid)")
    }

    // Microsoft Office needs AXEnhancedUserInterface to expose AX text (D.5). Same
    // set-once-per-pid discipline (review H2).
    private func applyEnhancedUserInterfaceIfNeeded(bundle: String, pid: pid_t) {
        guard OverrideStore.shared.resolved(bundle: bundle).needsEnhancedUserInterface == true else { return }
        guard pid > 0, !caretState.enhancedUIPids.contains(pid) else { return }
        caretState.enhancedUIPids.insert(pid)
        AXUIElementSetAttributeValue(axAppElement(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // Per-app/per-domain overrides. currentWebHost() costs several AX reads plus link
    // detection and only means anything for a browser, so it is memoized per focus session
    // and never paid at all in native apps.
    private func resolvedOverrides(bundle: String, kind: CaretHostKind) -> AppOverrides {
        guard kind == .webLike else { return OverrideStore.shared.resolved(bundle: bundle) }
        if let memo = caretState.webHostMemo, memo.bundle == bundle {
            return OverrideStore.shared.resolved(bundle: bundle, host: memo.host)
        }
        let host = currentWebHost()
        caretState.webHostMemo = (bundle, host)
        return OverrideStore.shared.resolved(bundle: bundle, host: host)
    }

    // MARK: - Invalidation

    // Drop every cached caret GEOMETRY, hide the ghost, and force the next probe to be a
    // real one. `dropClickAnchor` is false only on the mouse-down resync path, where the
    // anchor we must keep was recorded microseconds earlier.
    //
    // `clearTypography` is false by default because a window move, a resize, a scroll or a
    // display change moves pixels and changes NOTHING about the field's font or line
    // height. Throwing those away made every geometry invalidation cost a full AX font
    // re-read on the next probe — and a window drag fires dozens of them per second. Only
    // a focus change, where the next probe is a different field, clears them.
    func invalidateCaret(reason: String, dropClickAnchor: Bool = true, clearTypography: Bool = false) {
        lastCaretFix = nil
        lastCaretPoint = nil
        lastCaretFixAt = .distantPast
        charsSinceCaretFix = 0
        lineChangesSinceCaretFix = 0
        lastCaretHeight = CaretGeometry.defaultLineHeight
        shotCaretPoint = nil
        shotCaretApp = ""
        if dropClickAnchor {
            clickCaretPoint = nil
            clickCaretApp = ""
        }
        // lastProbeAt is deliberately NOT reset. Resetting it opened the coalescing window
        // for every single notification in a drag burst, so each one paid a full
        // synchronous probe plus a font re-read plus a screenshot/OCR restart. The cached
        // fix is already nil above, so a call that lands inside the window now returns nil
        // (hide the ghost) and schedules the trailing probe — never stale coordinates.
        if clearTypography {
            caretState.fontByElement.removeAll()
            caretState.lineHeightByElement.removeAll()
            caretState.webContentByElement.removeAll()
        }
        overlay.orderOut(nil)
        dlog("[\(activeAppKey)] caret invalidated: \(reason)")
    }

    // A focused-element change additionally forgets everything learned about the OLD
    // field — its typography, its element-level classification and its window's web host —
    // so nothing leaks from one field into the next inside the same app.
    //
    // The per-app width calibration (widthScaleByBundle) deliberately SURVIVES: it is an
    // EMA of how this app's text advances compare with our measurement, which is a property
    // of the app's renderer, not of one field. Dropping it on every focus change — i.e. on
    // every click and every app switch — meant it restarted from 1.0 forever and never
    // converged. Only the in-flight calibration epoch is reset.
    func invalidateCaretForFocusChange(dropClickAnchor: Bool = true) {
        invalidateCaret(reason: "focus change", dropClickAnchor: dropClickAnchor, clearTypography: true)
        caretState.webHostMemo = nil
        calibAnchor = nil
        calibPredicted = 0
    }

    // Display layout, Space changes and app exits all happen without any AX notification
    // we'd otherwise see. Installed once, lazily, from the first probe.
    func installGeometryObservers() {
        guard !caretState.geometryObserversInstalled else { return }
        caretState.geometryObserversInstalled = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            CoordinateUtil.invalidate()
            guard let self else { return }
            self.invalidateCaret(reason: "screen parameters")
            if self.completion != nil { self.showCompletionRemainder(reanchor: true) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.invalidateCaret(reason: "space change")
            if self.completion != nil { self.showCompletionRemainder(reanchor: true) }
        }
        // Everything keyed by pid has to die with the pid. macOS reuses pids, so a stale
        // entry is not merely a leak: a fresh Chrome that inherits a retired pid is already
        // in manualAccessibilityPids, never gets AXManualAccessibility, and therefore
        // never answers a single caret probe — or inherits an axHostileUntil cooldown and
        // is written off before it has been asked anything.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            guard pid > 0 else { return }
            self.caretState.manualAccessibilityPids.remove(pid)
            self.caretState.enhancedUIPids.remove(pid)
            self.caretState.probeHealthByPid[pid] = nil
            self.caretState.axHostileUntilByPid[pid] = nil
        }
    }

    // MARK: - Click anchor

    // Record where a left-click landed as a caret seed. `cgPoint` is CGEvent.location:
    // global, top-left origin, the same space AX uses — flip to AppKit bottom-left via
    // CoordinateUtil (primary-screen height). We store the click's vertical CENTER and
    // apply the half-line-height drop to the line bottom at consume time, not here.
    func recordClickCaret(at cgPoint: CGPoint) {
        clickCaretPoint = CoordinateUtil.axPointToAppKit(cgPoint)
        clickCaretAt = Date()
        clickCaretPending = true
    }

    // MARK: - ScrollWheelMonitor (B.4)

    // Install the scroll monitor once: scrolling a long doc leaves the AX/shot/click caret
    // anchors stale, so invalidate them and re-anchor, mirroring mouse-down invalidation.
    func startScrollMonitor() {
        guard caretState.scrollMonitor == nil else { return }
        let monitor = ScrollMonitor { [weak self] in self?.invalidateCaretOnScroll() }
        caretState.scrollMonitor = monitor
        monitor.start()
    }

    private func invalidateCaretOnScroll() {
        invalidateCaret(reason: "scroll")
        if completion != nil { showCompletionRemainder(reanchor: true) }
    }

    // MARK: - Screenshot caret support

    // The region (global Quartz, top-left) the screenshot caret locator should capture:
    // the focused element's bounds, narrowed to a few-line band around the best caret y
    // anchor we have. Returning a thin band instead of the whole window is what makes
    // the screenshot path cheap enough to run while typing. Main-thread only (reads AX).
    func caretCaptureClip() -> CGRect? {
        // The probe already read this element's frame; reuse it rather than paying two
        // more AX round-trips for the same answer.
        guard let rect = lastCaretFix?.elementFrameAX ?? focusedElementQuartzRect() else { return nil }
        let lineH = max(lastCaretHeight, shotCaretHeight, 16)
        // If the field is short (single/few-line input) the whole element IS the band.
        guard rect.height > lineH * 8, let anchorAppKitY = lastCaretPoint?.y ?? clickCaretPoint?.y else { return rect }
        let primaryMaxY = CoordinateUtil.primaryMaxY()
        // anchor is the line's bottom in AppKit (bottom-left); convert to the line's top
        // in Quartz (top-left), then pad a few lines each way.
        let quartzLineTop = primaryMaxY - anchorAppKitY - lineH
        let pad = lineH * 4
        let top = max(rect.minY, quartzLineTop - pad)
        let bottom = min(rect.maxY, quartzLineTop + lineH + pad)
        guard bottom - top >= 12 else { return rect }
        return CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top)
    }

    func refreshShotCaretIfNeeded() {
        // Uses Screen Recording (same permission as OCR context) but is independent
        // of the OCR-context toggle — caret placement should work even with it off.
        if shotCaretComputing { return }
        // Recompute when stale or after meaningful typing since the last fix. Each
        // recompute is a screenshot + OCR, so throttle hard: extrapolate horizontally
        // between captures and only re-capture after a real pause or large drift.
        let now = Date()
        let stale = now.timeIntervalSince(shotCaretAt) > 4.0 || shotCaretApp != activeAppKey
        let drift = abs(buffer.count - shotCaretBufferLen) > 24
        guard stale || drift else { return }
        // …and never more than once a second, whatever asks. Every invalidation clears the
        // shot anchor, which makes `stale` true, so a window-drag burst used to kick one
        // screenshot + Vision pass per notification — the single most expensive thing this
        // subsystem can do, fired dozens of times a second, for a caret nobody can see yet.
        guard now.timeIntervalSince(caretState.shotAttemptAt) >= 1.0 else { return }
        caretState.shotAttemptAt = now
        shotCaretComputing = true
        let appKey = activeAppKey
        let bufLen = buffer.count
        // Snapshot everything off `self` ON THE MAIN THREAD; the background closure
        // must not touch self.buffer / AX / NSWorkspace (off-main = crash/UB).
        let needle = String(String(buffer.suffix(40)).trimmingCharacters(in: .whitespacesAndNewlines).suffix(18)).lowercased()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let clip = caretCaptureClip()
        // NSScreen is main-affine; snapshot the primary-display height here so the
        // background OCR closure can do the Quartz→AppKit flip without touching NSScreen.
        let primaryMaxY = CoordinateUtil.primaryMaxY()
        backgroundQueue.async {
            let res = self.screenshotCaretRect(needle: needle, frontPID: frontPID, clip: clip, primaryMaxY: primaryMaxY)
            DispatchQueue.main.async {
                self.shotCaretComputing = false
                guard appKey == self.activeAppKey, let res else { return }
                self.shotCaretPoint = NSPoint(x: res.rect.maxX + 2, y: res.rect.minY)
                self.shotCaretCharWidth = res.charWidth
                self.shotCaretHeight = res.rect.height
                self.shotCaretBufferLen = bufLen
                self.shotCaretAt = Date()
                self.shotCaretApp = appKey
                // Re-place the live suggestion now that we know where the caret is.
                if self.completion != nil { self.showCompletionRemainder() }
            }
        }
    }

    // MARK: - Focused element + text context

    func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = axSystemWideElement()
        return axFocusedElement(of: system)
    }

    struct AXContext {
        var before: String
        var after: String
    }

    // Reads the text up to and after the caret from the focused element's AXValue
    // + selected range. Mirrors Cotypist's textUpToCursor / textAfterCursor split:
    // `before` drives the completion prompt; `after` lets us suppress mid-line
    // suggestions (don't autocomplete into the middle of existing text).
    func textAroundCursor(limit: Int) -> AXContext? {
        guard let element = focusedElement() else { return nil }
        guard let value = axString(element, kAXValueAttribute as String), !value.isEmpty else { return nil }
        // Guard the hot path: terminals and large editors expose enormous AXValues
        // (Ghostty reports ~400k chars). Copying that on every keystroke would jank
        // the event tap, so fall back to the keystroke buffer for oversized fields.
        guard value.utf16.count <= 20000 else {
            log("[\(activeAppKey)] AX value too large (\(value.count) chars); using key buffer")
            return nil
        }
        guard let rangeValue = axRead(element, kAXSelectedTextRangeAttribute as String) else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        let utf16 = value.utf16
        let cut = min(range.location, utf16.count)
        let caretIdx = String.Index(utf16Offset: cut, in: value)
        // stableTail, not suffix: a window that slides per keystroke makes the prompt
        // prefix differ on every request and defeats the helper's KV prefix cache.
        let before = stableTail(String(value[..<caretIdx]), max: limit)
        let after = String(String(value[caretIdx...]).prefix(limit))
        dlog("[\(activeAppKey)] AX text context valueChars=\(value.count) cursorUtf16=\(range.location) before=\(before.count) after=\(after.count)")
        return AXContext(before: before, after: after)
    }

    // True when the caret sits in the middle of a word/line of existing text, e.g.
    // editing "the qu|ick fox". Inline continuation there would be wrong, so we
    // suppress it — matching Cotypist's mid-line completion behavior.
    func isMidLine(after: String) -> Bool {
        // Suppress if ANY real text remains on the current line after the caret
        // (not just the immediately-adjacent char) — completing into "hello| world"
        // is as wrong as "the qu|ick". Trailing whitespace before a newline is fine.
        let restOfLine = after.prefix { $0 != "\n" && $0 != "\r" }
        return restOfLine.contains { !$0.isWhitespace }
    }

    // MARK: - Coordinate conversion (B.6, centralized)

    func axRectToAppKit(_ rect: CGRect) -> CGRect { CoordinateUtil.axRectToAppKit(rect) }

    // MARK: - Google Docs (B.5)

    // Detect docs.google.com with an empty AX text tree and prompt the user (once) to turn
    // on Docs' own screen-reader support — the only way Docs exposes a DOM/AX text tree,
    // and therefore the only way any caret tier can work there.
    func maybePromptGoogleDocs(element: AXUIElement, bundle: String, kind: CaretHostKind) {
        guard kind == .webLike else { return }
        guard let host = currentWebHostMemoized(bundle: bundle), host.hasSuffix("docs.google.com") else { return }
        // Only prompt if the field really has no text tree (a11y not yet enabled).
        if let v = axString(element, kAXValueAttribute as String), !v.isEmpty { return }
        // Once per launch per doc HOST. Keyed by host, not by bundle, so opening Docs in a
        // second browser still explains itself; and only for this launch, because the user
        // may simply not have acted on the alert yet — a permanent mark would mean the one
        // thing that makes Docs work is never mentioned again.
        guard !caretState.docsPromptedHosts.contains(host) else { return }
        caretState.docsPromptedHosts.insert(host)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Enable Google Docs accessibility"
            alert.informativeText = "Google Docs doesn't expose its text to typer until you turn on screen-reader support. In Docs: Tools → Accessibility… → enable \u{201C}Turn on screen reader support\u{201D} (\u{2318}\u{2325}Z). typer will then read the caret and show suggestions inline."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

    private func currentWebHostMemoized(bundle: String) -> String? {
        if let memo = caretState.webHostMemo, memo.bundle == bundle { return memo.host }
        let host = currentWebHost()
        caretState.webHostMemo = (bundle, host)
        return host
    }

    // The web host of the focused window (docs.google.com etc.), read over AX. Used for
    // the Google Docs branch (B.5) and domain-scoped AppOverrides resolution. Tries the
    // window's AXURL first, then falls back to parsing a URL out of the window title.
    // Callers go through the per-focus-session memo above; this is the uncached read.
    func currentWebHost() -> String? {
        guard let element = focusedElement() else { return nil }
        // Walk to the containing window.
        var windowEl: AXUIElement? = axRead(element, kAXWindowAttribute as String).map { $0 as! AXUIElement }
        if let w = windowEl { windowEl = axBound(w) }
        if let w = windowEl {
            if let urlVal = axRead(w, "AXURL") {
                if let url = urlVal as? URL, let h = url.host { return h.lowercased() }
                if let s = urlVal as? String, let url = URL(string: s), let h = url.host { return h.lowercased() }
            }
            if let title = axString(w, kAXTitleAttribute as String), let h = hostFromText(title) {
                return h
            }
        }
        return nil
    }

    // One detector for the process: building an NSDataDetector compiles a regex, and this
    // used to run on every override resolution, i.e. every placement.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private func hostFromText(_ text: String) -> String? {
        // Look for the first http(s) URL in the title; many browsers append the URL.
        guard let detector = TyperApp.linkDetector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range),
              let url = match.url, let host = url.host else { return nil }
        return host.lowercased()
    }
}
