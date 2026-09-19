import AppKit
import Foundation

// Pure caret geometry: every RULE about where the ghost may be drawn, expressed as a
// function of its arguments only. Nothing in this file touches NSScreen, AX, the clock
// or any global — the screen list and the flip pivot are passed in — so the whole
// placement contract is unit-testable headlessly (`scripts/caret_tests.swift`) and can
// never be quietly "fixed" by a stale cached screen.
//
// TyperApp+Caret owns the AX I/O, the caches and the invalidation; this file owns the
// arithmetic and the accept/reject decisions. The split exists because every historical
// mis-placement bug (ghost at the top-left of the primary display, 48pt text in Notion,
// the ghost jumping to the other monitor) was a rule bug, not an AX bug.

// The ladder step that produced a fix. `.marker`/`.bounds`/`.line` are AX rect producers
// and are authoritative; `.click`/`.ocr` are extrapolated anchors with no rect and are
// never remembered as an app's winning path.
enum CaretLadderPath: String, Equatable { case marker, bounds, line, click, ocr }

// One probe, one value. Everything downstream — ghost font, panel height, ghostWidth's
// measuring font, the screenshot capture clip — reads this struct instead of going back
// to AX, which is what keeps a placement to a handful of round-trips.
//
// `pointAppKit` is the caret's right edge (x) and the line's bottom (y), in AppKit
// (bottom-left origin) global coordinates. `elementFrameAX` is the focused element's
// frame in AX (top-left origin) space and is a hint only — never a placement source.
struct CaretFix {
    var pointAppKit: NSPoint
    var lineHeight: CGFloat
    var font: NSFont
    var color: NSColor
    var screenFrame: CGRect
    var elementFrameAX: CGRect?
    var path: CaretLadderPath
    var at: Date
    // True when `pointAppKit` is OUR OWN forward guess rather than the point this tier's
    // rect actually reported: a cached fix shifted by advanceGhost, or a probe whose
    // backward-snap guard handed back the optimistic point the ghost is already drawn at.
    // Such a point must never calibrate the width model — that is calibrating a
    // prediction against itself — and must never buy the ghost a fresh coasting budget.
    var extrapolated: Bool = false

    // Only a validated AX rect pins the caret exactly; the extrapolated tiers are best
    // effort and must not be used to calibrate the width model or seed a ladder memo.
    var isAuthoritative: Bool {
        !extrapolated && (path == .marker || path == .bounds || path == .line)
    }
}

// What a probe asked AX for, which is what decides how wide its answer may legitimately
// be. A caret probe that comes back 300pt wide is a selection or a whole text view, not
// a caret, and using it is how the ghost ends up on the wrong word.
enum CaretProbeKind {
    case collapsed   // zero-length range: the caret rect itself, or a terminal's cell
    case glyph       // one character: only its left or right edge is used
    case line        // a whole line: only its left or right edge is used

    // The width cap is an ASPECT-RATIO rule, not an absolute one: what makes a rect a
    // caret (or a glyph) rather than a selection is that it is narrow RELATIVE TO ITS
    // OWN HEIGHT. The old absolute caps (collapsed <= 4pt, glyph <= 24pt) rejected two
    // perfectly real answers — a block-cursor terminal, which answers a zero-length range
    // with the CELL at the caret (~8pt wide on a 17pt line, and proportionally wider on a
    // big one), and any glyph above roughly a 30pt font, emoji and ligatures included —
    // so those hosts never got a ghost at all. The absolute values survive as FLOORS, so
    // nothing that used to be accepted stops being accepted on a small line.
    func maxWidth(forHeight height: CGFloat) -> CGFloat {
        let h = height.isFinite && height > 0 ? height : CaretGeometry.defaultLineHeight
        switch self {
        case .collapsed: return max(4, 0.8 * h)
        case .glyph: return max(24, 1.5 * h)
        case .line: return .greatestFiniteMagnitude
        }
    }

    // The cap that applies when the focused element's frame is UNKNOWN.
    //
    // The aspect-ratio caps above are safe only because the containment and whole-element
    // checks run alongside them: they bound a rect by its own height, and a rect that lies
    // about its height ("the caret is 190pt tall") then buys itself a proportionally
    // absurd width. With no element frame there is nothing left to catch that, so the
    // aspect rule keeps its floor (nothing that used to be accepted on a normal line stops
    // being accepted) but gains an absolute ceiling — the pre-aspect values, which is
    // exactly the behaviour this tier had before the ratio rule existed.
    //
    // `.line` has no entry because a line probe is not admissible at all without a frame:
    // "the whole element" is the commonest wrong answer to a line query, and the check that
    // recognises it needs the element.
    func strictMaxWidth(forHeight height: CGFloat) -> CGFloat {
        let h = height.isFinite && height > 0 ? height : CaretGeometry.defaultLineHeight
        switch self {
        case .collapsed: return max(4, min(0.8 * h, 20))
        case .glyph: return max(24, min(1.5 * h, 60))
        case .line: return 0
        }
    }
}

enum CaretGeometry {
    // Line-height sanity window. Below 6pt nothing is readable text.
    static let minLineHeight: CGFloat = 6
    // The ceiling used for TYPOGRAPHY: past 72pt we stop letting the line drive the ghost
    // font (it is already capped at 28pt anyway) because a "line" that tall is a heading
    // block, and believing it is what produced 48pt ghost text in Notion headings.
    static let maxLineHeight: CGFloat = 72
    // The ceiling used for VALIDATION, which is a much weaker claim: a Keynote title, a
    // 48pt document heading and a zoomed-in page really do report 80-190pt line boxes,
    // and rejecting those rects meant no ghost at all in exactly the places people write
    // headlines. Garbage is still bounded — by element-frame containment, the aspect-ratio
    // width caps, single-screen containment, the AX-space zero-origin check and the
    // whole-element check — so the height gate only has to exclude the absurd.
    static let maxCaretRectHeight: CGFloat = 200
    // Used when no tier gave us a measured line (click/OCR anchors in a fresh field).
    static let defaultLineHeight: CGFloat = 18
    // Ghost font bounds. The upper bound is also relative to the line (see ghostFontSizing).
    static let minFontSize: CGFloat = 9
    static let maxFontSize: CGFloat = 28
    // How far outside its element's frame a caret rect may sit before we call it garbage.
    static let elementFrameSlack: CGFloat = 4

    // Forward-extrapolation budget: how long / how far the ghost may coast on a cached
    // fix while the user types through it, before we hide rather than guess.
    static let maxExtrapolationAge: TimeInterval = 0.6
    static let maxExtrapolationChars = 40
    // Click-anchor budget: much longer (a click really does pin the caret) but still
    // bounded, and additionally dropped near the field's right edge (soft wrap).
    static let clickAnchorMaxAge: TimeInterval = 20
    static let clickAnchorMaxChars = 80
    static let clickAnchorEdgeSlack: CGFloat = 8

    // MARK: - Coordinate flip

    // AX reports global coordinates with a top-left origin anchored at the PRIMARY
    // display; AppKit uses a bottom-left origin anchored at the same display. The flip
    // therefore pivots on the primary screen's height, never on the height of whichever
    // screen the rect happens to land on. AX rects are in POINTS: never scale by
    // backingScaleFactor here (that is ScreenCaptureKit/Vision pixel math).
    @inline(__always)
    static func flip(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryMaxY - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    @inline(__always)
    static func flip(_ point: CGPoint, primaryMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryMaxY - point.y)
    }

    // MARK: - Rect validation

    struct ValidatedCaretRect {
        var rectAppKit: CGRect
        var screenFrame: CGRect
        // The rect passed every structural check but disagreed with the line height this
        // element last gave us. The caller accepts it and OVERWRITES the trusted height
        // (see below) — this flag exists so it can say so in the log.
        var lineHeightChanged: Bool = false
    }

    // Accept or reject an AX caret rect. EVERY structural check runs in AX SPACE, before
    // the flip: the classic AX garbage answer is (0, 0, w, h), and flipping that first
    // turns it into a perfectly plausible-looking rect at the top-left of the primary
    // display — which is exactly where the ghost used to land thousands of times a
    // session. Only the screen-containment check can run after the flip, because screens
    // are AppKit-space.
    //
    // `trustedLineHeight` is the last height this same element gave us. It is a HINT, not
    // a veto: a rect that clears every other check but falls outside the trusted window is
    // accepted and reported with `lineHeightChanged`, so the caller can overwrite the
    // trusted value. The window used to reject instead, and because the trusted height was
    // only ever refreshed on a SUCCESSFUL probe, one style change on a live element (a
    // 17pt paragraph turned into a 40pt heading) locked the ghost out of that element for
    // the rest of the session: every real rect failed the window, so the window never
    // learned. Catching garbage is the other checks' job and they bound it without help.
    static func validateAXCaretRect(_ rectAX: CGRect,
                                    kind: CaretProbeKind,
                                    elementFrameAX: CGRect?,
                                    trustedLineHeight: CGFloat?,
                                    primaryMaxY: CGFloat,
                                    screens: [CGRect]) -> ValidatedCaretRect? {
        guard rectAX.origin.x.isFinite, rectAX.origin.y.isFinite,
              rectAX.size.width.isFinite, rectAX.size.height.isFinite else { return nil }
        guard rectAX.size.height > 0, rectAX.size.width >= 0 else { return nil }
        guard rectAX.size.height >= minLineHeight, rectAX.size.height <= maxCaretRectHeight else { return nil }
        var lineHeightChanged = false
        if let line = trustedLineHeight, line > 0 {
            lineHeightChanged = rectAX.size.height < 0.6 * line || rectAX.size.height > 2.2 * line
        }
        // Is there an element frame worth checking against? Everything that bounds a
        // too-generous answer — containment, the whole-element test, and therefore the
        // aspect-ratio width caps that lean on them — depends on this.
        let element: CGRect? = elementFrameAX.flatMap { $0.width > 4 && $0.height > 4 ? $0 : nil }
        // A LINE probe asks for a whole line box, so its only defence against being handed
        // the whole text view instead is the element frame. Without one, `.line` had no
        // width cap at all and no containment check: a 600x180 "line" — three paragraphs of
        // a text view — was accepted and the ghost went to the top of the block. A line tier
        // with no frame is simply not admissible; the collapsed/glyph tiers still are.
        guard element != nil || kind != .line else { return nil }
        if kind == .line {
            // A line box may legitimately be tall (a heading), but it is ONE line: at most
            // a little over the line height this element last gave us, or — with nothing
            // measured yet — past 60pt it is a block, not a line.
            let cap = (trustedLineHeight.map { $0 > 0 ? 2.2 * $0 : 60 }) ?? 60
            guard rectAX.size.height <= cap else { return nil }
        }
        if element == nil {
            // No frame: the generous validation ceiling (200pt, which exists for Keynote
            // titles and zoomed documents inside a KNOWN element) is not earned here.
            guard rectAX.size.height <= maxLineHeight else { return nil }
        }
        let widthCap = element == nil
            ? kind.strictMaxWidth(forHeight: rectAX.size.height)
            : kind.maxWidth(forHeight: rectAX.size.height)
        guard rectAX.size.width <= widthCap else { return nil }
        // Classic bogus origin, checked where it is still recognisable.
        guard rectAX.origin != .zero else { return nil }
        if let element {
            // The caret must live inside the field it belongs to (with a little slack for
            // apps that report the caret flush against, or a hair outside, the edge).
            guard element.insetBy(dx: -elementFrameSlack, dy: -elementFrameSlack).contains(rectAX) else { return nil }
            // "The whole text view" is a very common answer to "where is the caret".
            guard rectAX.size != element.size else { return nil }
        }
        let flipped = flip(rectAX, primaryMaxY: primaryMaxY)
        guard flipped.origin.y.isFinite else { return nil }
        // A real caret sits wholly on one display. Zero matches means off-screen or
        // straddling a boundary — both are "we don't know", and we never guess. SEVERAL
        // matches used to mean the same thing, which silently broke mirrored displays:
        // mirroring reports the same frame twice, so every single rect was rejected and
        // the ghost never appeared at all. Identical frames are one display described
        // twice; only genuinely DIFFERENT overlapping frames are ambiguous.
        let hits = screens.filter { $0.contains(flipped) }
        guard let screen = hits.first, hits.allSatisfy({ $0 == screen }) else { return nil }
        return ValidatedCaretRect(rectAppKit: flipped, screenFrame: screen,
                                  lineHeightChanged: lineHeightChanged)
    }

    // Where the caret's x is inside a validated COLLAPSED rect.
    //
    // A zero-length range normally answers with a hairline rect whose right edge is the
    // caret. A block-cursor terminal answers with the CELL at the caret instead — the
    // character the caret sits ON — so there the caret is the cell's LEFT edge; taking
    // maxX would place the ghost one whole cell to the right of the cursor. The old 4pt
    // collapsed cap made this unreachable (every cell was rejected), so the same 4pt is
    // what separates the two readings: at or below it the rect is a caret, above it a cell.
    static let hairlineCaretMaxWidth: CGFloat = 4

    @inline(__always)
    static func collapsedCaretX(in rect: CGRect) -> CGFloat {
        rect.width > hairlineCaretMaxWidth ? rect.minX : rect.maxX
    }

    // MARK: - Ghost typography

    struct GhostFontSizing {
        var size: CGFloat
        var trusted: Bool      // false => the AX font disagreed with the measured line; use a system font
        var panelHeight: CGFloat
    }

    // Decide the ghost's point size from the AX font and the MEASURED line height, with
    // the line height as the authority. An AX font is only believed when its own line box
    // is roughly the line we measured; a Notion H1 that reports a 48pt font for an 18pt
    // caret rect is reporting the block's style, not the run at the caret, and believing
    // it is what produced "massive text". The final size can never exceed 1.35x the line.
    static func ghostFontSizing(axFontPointSize: CGFloat?,
                                axFontHeight: CGFloat?,
                                lineHeight: CGFloat,
                                adjustment: CGFloat) -> GhostFontSizing {
        let line = max(1, lineHeight.isFinite ? lineHeight : defaultLineHeight)
        var trusted = false
        var size = nominalGhostFontSize(forLineHeight: line)
        if let point = axFontPointSize, let height = axFontHeight,
           point.isFinite, height.isFinite, point > 0,
           height >= 0.55 * line, height <= 1.7 * line {
            trusted = true
            size = point
        }
        let factor = (adjustment.isFinite && adjustment > 0) ? adjustment : 1
        let final = clamp(size * factor, minFontSize, min(maxFontSize, line * 1.35))
        return GhostFontSizing(size: final, trusted: trusted,
                               panelHeight: panelHeight(forLineHeight: line, fontSize: final))
    }

    // The ghost size implied by the line alone, i.e. what we render when the AX font is
    // missing or not believable. Factored out so panelHeight can predict it.
    static func nominalGhostFontSize(forLineHeight lineHeight: CGFloat) -> CGFloat {
        let line = max(1, lineHeight.isFinite ? lineHeight : defaultLineHeight)
        return clamp(line * 0.62, minFontSize, min(maxFontSize, line * 1.35))
    }

    // The overlay panel's height.
    //
    // The panel's ORIGIN is the caret line's bottom and it grows upward, and GhostView
    // centres the text box inside it — so the panel height is really a baseline control:
    // the ghost's baseline lands at (panelHeight/2 - 0.39 * fontSize) above the line
    // bottom, because a text box of ~1.2x the point size centred in the panel puts its
    // baseline ~0.21x the point size up from its own bottom edge.
    //
    // The host's own baseline sits ~0.21 of the LINE box above the line bottom (the
    // descender fraction), so matching them gives
    //     panelHeight = 2 * (0.21 * line + 0.39 * fontSize) = 0.42 * line + 0.78 * fontSize
    // which reproduces today's behaviour almost exactly on ordinary text (a 13pt font on
    // a 17pt line wants 17.3pt, and the old rule said 17) while finally doing something
    // sensible on a tall line. The old rule — the line height clamped to 40 — centred a
    // 40pt panel against a 72pt+ line box, which dropped the ghost ~16pt below a Keynote
    // title's baseline; here a 72pt line asks for 52pt and a 150pt line for ~83pt, and in
    // both cases the ghost lands on the host's baseline instead of under it.
    //
    // `fontSize` is the size the ghost will actually be drawn at. Callers that do not know
    // it yet get the size the line alone implies, which is within a point or two.
    static func panelHeight(forLineHeight lineHeight: CGFloat, fontSize: CGFloat? = nil) -> CGFloat {
        let line = clamp(lineHeight.isFinite ? lineHeight : defaultLineHeight,
                         minLineHeight, maxCaretRectHeight)
        let size = fontSize.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? nominalGhostFontSize(forLineHeight: line)
        return max(12, 0.42 * line + 0.78 * size)
    }

    // The line height the TYPOGRAPHY rules may see. Placement uses the real measured line
    // (a 150pt Keynote title really is 150pt tall and the panel has to know), but the
    // ghost font is bounded by 28pt regardless, and letting a heading-sized line through
    // the font rules only widens the window in which an absurd AX font is "trusted".
    @inline(__always)
    static func typographyLineHeight(_ lineHeight: CGFloat) -> CGFloat {
        clamp(lineHeight.isFinite ? lineHeight : defaultLineHeight, minLineHeight, maxLineHeight)
    }

    // MARK: - Screen selection and clamping

    // The screen that owns a caret POINT. Picking by point (not by the up-to-760pt-wide
    // ghost frame, and never NSScreen.main) is what stops the ghost hopping to the
    // neighbouring display when you type near the edge of this one.
    static func screenContaining(point: CGPoint, in screens: [CGRect]) -> CGRect? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        if let hit = screens.first(where: { $0.contains(point) }) { return hit }
        // CGRect.contains is half-open, so a caret exactly on a screen's top or right
        // boundary belongs to no screen at all. Allow a 1pt tolerance, nearest first.
        let tolerance: CGFloat = 1
        return screens
            .filter { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            .min { squaredDistance(from: point, to: $0) < squaredDistance(from: point, to: $1) }
    }

    // Fit the ghost onto its screen WITHOUT walking it back over the user's text: the
    // frame's x is the caret, so a ghost that doesn't fit to the right is truncated, never
    // shifted left. (The old min/max clamp pushed a too-wide ghost off the left edge and
    // straight across whatever had just been typed.)
    static func clampGhostFrame(_ frame: CGRect, toScreen screen: CGRect, inset: CGFloat = 8) -> CGRect {
        let visible = screen.insetBy(dx: inset, dy: inset)
        guard visible.width > 0, visible.height > 0 else { return frame }
        var result = frame
        // x only ever moves RIGHT (a caret in the screen's outer margin).
        result.origin.x = max(result.origin.x, visible.minX)
        result.size.width = max(0, min(result.width, visible.maxX - result.origin.x))
        result.size.height = min(result.height, visible.height)
        result.origin.y = min(max(result.origin.y, visible.minY), visible.maxY - result.height)
        return result
    }

    // MARK: - Budgets

    // May the ghost still coast on the last fix, or must it hide until a fresh one lands?
    static func extrapolationWithinBudget(age: TimeInterval, chars: Int, lineChanges: Int) -> Bool {
        age >= 0 && age <= maxExtrapolationAge && chars <= maxExtrapolationChars && lineChanges == 0
    }

    // Is a click anchor still a believable caret? Bounded in time and typing, and dropped
    // once the extrapolated advance approaches the field's right edge, because past that
    // the text has soft-wrapped onto a line we can't see.
    static func clickAnchorUsable(age: TimeInterval,
                                  chars: Int,
                                  containsNewline: Bool,
                                  anchorX: CGFloat,
                                  advance: CGFloat,
                                  elementMaxX: CGFloat?) -> Bool {
        guard age >= 0, age <= clickAnchorMaxAge, chars <= clickAnchorMaxChars, !containsNewline else { return false }
        if let maxX = elementMaxX, maxX.isFinite, anchorX + advance > maxX - clickAnchorEdgeSlack { return false }
        return true
    }

    // MARK: - Helpers

    @inline(__always)
    static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = point.x < rect.minX ? rect.minX - point.x : (point.x > rect.maxX ? point.x - rect.maxX : 0)
        let dy = point.y < rect.minY ? rect.minY - point.y : (point.y > rect.maxY ? point.y - rect.maxY : 0)
        return dx * dx + dy * dy
    }
}
