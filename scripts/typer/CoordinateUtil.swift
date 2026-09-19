import AppKit
import Foundation

// Centralized AX↔AppKit coordinate conversion (spec B.6).
//
// AX APIs report global coordinates with a top-left origin anchored at the top-left of
// the PRIMARY display (the menu-bar / zero-origin screen) — the same space as
// CGEvent / CGDisplayBounds. AppKit (NSPanel.setFrame, NSScreen.frame) uses a
// bottom-left origin anchored at the bottom-left of that SAME primary screen. The flip
// must therefore use the primary screen's height, NOT the height of whatever screen the
// rect happens to land on; using the local screen's maxY breaks on multi-monitor setups.
// This is the `UIElementUtilities.flippedScreenBounds:` semantics Cotypist centralizes.
//
// The arithmetic itself lives in CaretGeometry (pure, unit-tested); this enum is only the
// main-thread convenience that supplies the pivot.
//
// IMPORTANT: AX rects are in POINTS — never divide by backingScaleFactor here (that is
// only for ScreenCaptureKit / Vision pixel math).
enum CoordinateUtil {
    // Cached because every caret probe needs it and it only changes when the display
    // layout does. Main-thread only (NSScreen is main-affine); the caret subsystem calls
    // `invalidate()` from its NSApplication.didChangeScreenParameters observer.
    private static var cachedPrimaryMaxY: CGFloat?

    // The primary (zero-origin) display's max-Y, used as the flip pivot. NSScreen is
    // main-affine, so callers off the main thread must snapshot this on the main thread
    // and pass it to `flip(_:primaryMaxY:)` instead of calling this.
    //
    // There is deliberately NO NSScreen.main fallback: main is "the screen with the key
    // window", which on a multi-monitor setup is routinely not the zero-origin display,
    // and pivoting on the wrong one silently places every ghost on the wrong screen. With
    // no zero-origin screen (no displays attached) we return 0, which makes every flipped
    // rect fail validation — the ghost hides instead of landing somewhere invented.
    static func primaryMaxY() -> CGFloat {
        if let cached = cachedPrimaryMaxY { return cached }
        // 0 is the FAILURE sentinel, not an answer: it means no zero-origin screen was
        // found, which happens transiently while displays are waking, being reattached or
        // switching Spaces. Caching it made that transient permanent until the next
        // didChangeScreenParameters — every flip pivoted on 0 and every rect failed
        // validation, so the ghost stayed hidden long after the displays came back. Cache
        // only a real pivot; re-ask (one NSScreen.screens read) while there isn't one.
        guard let value = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY else {
            return 0
        }
        cachedPrimaryMaxY = value
        return value
    }

    // Drop the cached pivot after a display-layout change.
    static func invalidate() { cachedPrimaryMaxY = nil }

    // Flip a global rect between AX (top-left) and AppKit (bottom-left), using an
    // explicitly supplied primary-screen height (safe to call off the main thread).
    @inline(__always)
    static func flip(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CaretGeometry.flip(rect, primaryMaxY: primaryMaxY)
    }

    // Main-thread convenience: AX rect (top-left, primary-anchored) → AppKit rect.
    static func axRectToAppKit(_ rect: CGRect) -> CGRect {
        CaretGeometry.flip(rect, primaryMaxY: primaryMaxY())
    }

    // Flip a single global point (e.g. CGEvent.location) into AppKit coords.
    static func axPointToAppKit(_ point: CGPoint) -> NSPoint {
        CaretGeometry.flip(point, primaryMaxY: primaryMaxY())
    }
}
