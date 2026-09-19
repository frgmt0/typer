import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Event-driven ghost re-anchoring. The fixed 90ms/280ms re-anchor timers exist
// because our event tap sees a keystroke BEFORE the host app applies it — reading
// the AX caret immediately would return a stale position. But "how long until the
// app catches up" varies per app and per moment; a timer is always either too
// early (stale read) or too late (the ghost lags). An AXObserver removes the
// guessing: the host app posts AXValueChanged/AXSelectedTextChanged the moment it
// actually applies the edit, and we re-anchor right then. The timers stay as a
// fallback for apps that don't emit AX notifications.

// Defer-release wrapper for the AXObserver (spec D.2, research/stability.md §1.3).
//
// Releasing the last reference to an `AXObserver` synchronously WHILE STILL on the
// observer's own callback stack re-enters AX framework teardown (run-loop source
// removal, port invalidation) re-entrantly — a classic deadlock / use-after-free
// vector against the WindowServer/host during rapid focus churn. Cotypist never
// releases inline: setting the slot (including to nil) captures the previous observer
// and drops it on the next main-loop turn, after the callback frame has unwound.
// We mirror that exactly. typer keeps a single observer (re-pointed per app), so one
// shared deferred slot is enough; the per-PID/per-element state stays on TyperApp.
final class DeferredAXObserver {
    static let shared = DeferredAXObserver()
    private(set) var value: AXObserver?

    // Assign the live observer; the previous one is released off the callback stack.
    func set(_ new: AXObserver?) {
        let old = value
        value = new
        if let old { DispatchQueue.main.async { _ = old } }   // release after the frame unwinds
    }
}

// Background-context debounce state (spec C.2). An AXSelectedTextChanged notification
// means the user typed/moved the caret, so the cached background is now stale — but we
// must NOT run the expensive screenshot/OCR/AX-walk synchronously on that notification.
// Instead we mark the cache dirty and schedule a single coalesced refresh ~600 ms after
// the LAST change (Cotypist's lastRefreshCheck gate). A low-frequency safety timer
// (TyperApp+Context) still covers apps that never post AX notifications. File-private so
// it lives entirely in W1B's files without adding stored props to TyperApp.swift.
private let axBackgroundDebounce: TimeInterval = 0.6
private var axLastChangeAt = Date.distantPast
private var axBackgroundRefreshScheduled = false

// Window move/resize debounce. A drag posts AXWindowMoved continuously, and each
// re-anchor is a fresh AX caret probe — so the ghost hides immediately (the cached
// point is stale the instant the window starts moving) and exactly one re-anchor runs
// after the drag settles.
private let axWindowReanchorDebounce: TimeInterval = 0.12
private var axLastWindowChangeAt = Date.distantPast
private var axWindowReanchorScheduled = false

extension TyperApp {
    // (Re)point the observer at the frontmost app, and at its focused element.
    // Cheap when nothing changed; call freely on app switches and focus moves.
    // `dropClickAnchor` is forwarded to the focused-element reset: a click that moves focus
    // records its caret seed microseconds before this runs, and that seed must survive.
    // Returns true when this call already performed the focused-element caret reset, so an
    // app-switch caller doesn't have to do it a second time.
    @discardableResult
    func updateAXObserver(dropClickAnchor: Bool = true) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        // Never observe our own process (Settings/onboarding windows): focus changes
        // inside a SwiftUI window fire AX callbacks that read its a11y tree and beachball
        // the main thread. Tear down and wait for a real app to come forward.
        if pid == ProcessInfo.processInfo.processIdentifier {
            if axObserverPID != 0 { teardownAXObserver(); axObserverPID = 0 }
            return false
        }
        if pid != axObserverPID {
            // Focus/app change: tear down + recreate with a DEFERRED release rather than
            // un-registering per-element notifications on a possibly-dead element (D.2).
            teardownAXObserver()
            guard pid > 0 else { return false }
            var obs: AXObserver?
            let cb: AXObserverCallback = { _, element, notification, refcon in
                guard let refcon else { return }
                let app = Unmanaged<TyperApp>.fromOpaque(refcon).takeUnretainedValue()
                app.handleAXNotification(notification as String, element: element)
            }
            guard AXObserverCreate(pid, cb, &obs) == .success, let obs else {
                dlog("AXObserver create failed pid=\(pid)")
                return false
            }
            axObserver = obs
            DeferredAXObserver.shared.set(obs)
            axObserverPID = pid
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            // Focus changes are observed app-wide so we can re-target the per-element
            // notifications without polling. The application element is bound to the 50 ms
            // messaging timeout (D.1) so a wedged app can't stall registration.
            let appElement = axAppElement(pid)
            AXObserverAddNotification(obs, appElement, kAXFocusedUIElementChangedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
            dlog("AXObserver attached pid=\(pid)")
        }
        return refreshObservedElement(dropClickAnchor: dropClickAnchor)
    }

    // Subscribe to edit notifications on the CURRENT focused element (they cannot
    // be observed app-wide; AX notifications are registered per element).
    //
    // We deliberately DO NOT call AXObserverRemoveNotification on the previously
    // focused element (D.2 / research/stability.md §1.1): on a focus change that
    // element may already be dead (its app crashed/quit), and removing a notification
    // on a dead element is a known hang/crash vector. Stale per-element registrations
    // are harmless — they simply stop firing and die with the deferred observer when the
    // app changes. We only swap which element we *track* and add the new registrations.
    // Returns true when the focused element actually changed, so callers can reset the
    // per-field caret state (font, line height, width calibration) instead of letting one
    // field's typography leak into the next.
    @discardableResult
    func refreshObservedElement(dropClickAnchor: Bool = true) -> Bool {
        guard let obs = axObserver else { return false }
        let el = focusedElement()
        if let old = axObservedElement, let el, CFEqual(old, el) { return false }
        if axObservedElement == nil && el == nil { return false }
        // nil while we were tracking something is a FAILED READ, not a focus change. A
        // wedged host, an app mid-relaunch or a 50 ms timeout all return nil here, and
        // treating that as "the user moved to a different field" threw away the font, the
        // line height, the width calibration and the click anchor — twice, since the next
        // call then saw the element come back and counted that as a second change. Keep
        // tracking what we had and wait for a read that answers.
        if el == nil, axObservedElement != nil {
            dlog("AXObserver focused-element read returned nil; keeping the tracked element")
            return false
        }
        axObservedElement = el
        // Everything we learned about the previous field is now wrong (D10).
        invalidateCaretForFocusChange(dropClickAnchor: dropClickAnchor)
        guard let el else { return true }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, el, kAXValueChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, el, kAXSelectedTextChangedNotification as CFString, refcon)
        // A window move or resize relocates the caret with no value/selection change at
        // all, so the cached fix silently points at the wrong pixels until the next
        // keystroke. Registered on the field's window (same deliberate no-remove policy as
        // the element registrations above: the old window may already be dead).
        if let window = axRead(el, kAXWindowAttribute as String), CFGetTypeID(window) == AXUIElementGetTypeID() {
            let windowEl = axBound(window as! AXUIElement)
            let moved = AXObserverAddNotification(obs, windowEl, kAXWindowMovedNotification as CFString, refcon)
            let resized = AXObserverAddNotification(obs, windowEl, kAXWindowResizedNotification as CFString, refcon)
            // These two silently fail in a fair number of hosts (a window element that
            // doesn't support the notification, a timeout). Without the status there is no
            // way to tell "the app never posts window-moved" from "we never asked".
            dlog("AXObserver window notifications moved=\(moved.rawValue) resized=\(resized.rawValue)")
        }
        return true
    }

    func teardownAXObserver() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            // Release the observer off the callback stack (deferred), never inline (D.2).
            DeferredAXObserver.shared.set(nil)
        }
        axObserver = nil
        axObservedElement = nil
        axObserverPID = 0
    }

    // Runs on the main run loop (the observer's source is scheduled there).
    func handleAXNotification(_ name: String, element: AXUIElement) {
        if name == kAXFocusedUIElementChangedNotification as String {
            // A focus move inside the SAME app used to reset nothing, so the old field's
            // font, line height, click anchor and width calibration followed the caret
            // into the new one. refreshObservedElement now drops all of it and hides the
            // ghost; we deliberately do NOT re-place it, because a suggestion generated
            // for the previous field has no business appearing in this one. The next
            // keystroke re-anchors (or regenerates) it. A click's caret seed still
            // survives: the click IS the new field's caret placement.
            refreshObservedElement(dropClickAnchor: !clickCaretPending)
            return
        }
        // The window moved or resized under us: every cached caret coordinate is stale.
        // A drag posts this continuously (dozens per second), so the two halves are split:
        // hiding the ghost and dropping the cached geometry is free and has to happen on
        // every event, while re-anchoring costs a fresh AX probe and happens ONCE, after
        // the drag stops.
        if name == kAXWindowMovedNotification as String || name == kAXWindowResizedNotification as String {
            invalidateCaret(reason: name == kAXWindowMovedNotification as String ? "window moved" : "window resized")
            overlay.orderOut(nil)
            scheduleWindowReanchor()
            return
        }
        // The user typed/moved the caret: the cached background is now stale. Mark it
        // dirty and schedule ONE debounced refresh after the burst settles (C.2). The
        // expensive capture never runs on this synchronous notification path.
        if name == kAXSelectedTextChangedNotification as String {
            scheduleBackgroundRefreshDebounced()
            // …and, when the change was NOT ours, re-sync the buffer. This is the catch-all
            // for caret moves that never reach the event tap at all: Find (⌘G's jump), a
            // menu command, a click inside a webview the tap sees only as a mouse-down, an
            // app programmatically repositioning the insertion point.
            //
            // The guard matters, because this notification also fires on every single
            // character the user types, and re-syncing there would put an AX round-trip on
            // the keystroke path and fight the typing buffer for ownership of its own text.
            // Three conditions, all cheap and all main-thread:
            //   1. no real text keystroke in the last 150 ms (`lastUserTypedAt` is bumped
            //      ONLY by typing — navigation deliberately does not touch it, so an arrow
            //      key still gets through here);
            //   2. none of our own injected events in the last 150 ms (`lastSyntheticAt` is
            //      stamped in the observer tap when a synthetic-marked event comes back, so
            //      it covers every injection path: accept, typo fix, emoji, paste);
            //   3. the re-sync itself is the same trailing-edge debounce the keyboard path
            //      uses, which re-arms while typing continues — so even if an app posts its
            //      notification late enough to slip past (1), the work still lands in a
            //      typing pause rather than mid-burst, and `invalidateAndResync`'s
            //      generation-serial guard abandons it if typing raced in.
            //   4. nothing was put on screen in the last 400 ms. Painting a completion is
            //      itself an edit as far as some hosts are concerned, and a notification
            //      for the keystroke that triggered the generation can arrive AFTER the
            //      suggestion it produced is already up — so this window is measured from
            //      the paint, not only from the keystroke, and it is the cheap, robust
            //      version of "was this us?".
            //   5. nothing is mid-generation. This is the backstop for an app that posts
            //      its notification LATE (slower than 150 ms after the keystroke that
            //      caused it): while a debounce timer is armed or a request is in the
            //      helper, the change we are being told about is still ours, and tearing
            //      the suggestion down here would make it flash and vanish. A change that
            //      really is external, though, must not simply evaporate because it landed
            //      inside that window — it is parked and drained the moment the window
            //      closes (`drainExternalSelectionChange`).
            let now = Date()
            if now.timeIntervalSince(lastUserTypedAt) > TyperApp.axSelfChangeWindow,
               now.timeIntervalSince(lastSyntheticAt) > TyperApp.axSelfChangeWindow,
               now.timeIntervalSince(lastPresentedAt) > TyperApp.axPresentedWindow {
                if requestInFlight || (debounce?.isValid ?? false) {
                    pendingExternalSelectionChange = true
                } else {
                    dismissForExternalEdit(reason: "AXSelectedTextChanged")
                }
            }
        }
        // The app just applied an edit — its AX caret is fresh NOW. Re-anchor on
        // the next runloop tick, coalescing bursts (apps can post several
        // notifications per keystroke).
        guard completion != nil, !axNotifyPending else { return }
        axNotifyPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.axNotifyPending = false
            guard self.completion != nil else { return }
            self.showCompletionRemainder(reanchor: true)
        }
    }

    // One caret re-anchor ~120 ms after the LAST window move/resize. Re-arms itself while
    // the drag continues, so a two-second drag costs one AX probe rather than a hundred.
    func scheduleWindowReanchor() {
        axLastWindowChangeAt = Date()
        guard !axWindowReanchorScheduled else { return }
        axWindowReanchorScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + axWindowReanchorDebounce) { [weak self] in
            axWindowReanchorScheduled = false
            guard let self else { return }
            if Date().timeIntervalSince(axLastWindowChangeAt) < axWindowReanchorDebounce - 0.02 {
                self.scheduleWindowReanchor()      // still dragging
                return
            }
            guard self.completion != nil else { return }
            self.showCompletionRemainder(reanchor: true)
        }
    }

    // Coalesce a flurry of AXSelectedTextChanged notifications into a single background
    // refresh ~600 ms after the last change. Marks the cache dirty so the refresh is not
    // skipped by its time-throttle, then fires it once the user pauses (C.2). Cheap and
    // main-thread only; the heavy work is dispatched off-main inside refreshBackgroundIfNeeded.
    func scheduleBackgroundRefreshDebounced() {
        axLastChangeAt = Date()
        guard !axBackgroundRefreshScheduled else { return }
        axBackgroundRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + axBackgroundDebounce) { [weak self] in
            axBackgroundRefreshScheduled = false
            guard let self else { return }
            // If more changes arrived during the window, wait for the next pause.
            if Date().timeIntervalSince(axLastChangeAt) < axBackgroundDebounce - 0.05 {
                self.scheduleBackgroundRefreshDebounced()
                return
            }
            // Event-driven refresh: bypass the time-throttle (the user just paused after
            // editing, which is exactly when fresh background helps) but still single-flight.
            self.refreshBackgroundIfNeeded(force: true)
        }
    }
}
