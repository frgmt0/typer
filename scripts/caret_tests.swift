import AppKit
import Foundation

// Headless unit tests for the caret placement RULES (scripts/typer/CaretGeometry.swift).
//
// Everything decided by CaretGeometry is a pure function of its arguments — screens and
// the flip pivot are passed in — so the whole "where may the ghost be drawn" contract is
// testable without a window server, an accessibility grant or a host app. Run with
// `scripts/run_caret_tests.sh`; the binary exits non-zero on the first failing suite.
//
// AX behaviour inside real apps is NOT covered here and cannot be: this file protects the
// arithmetic and the accept/reject decisions, which is where every historical
// mis-placement bug actually lived.

// A reference display layout used throughout: a primary laptop display at the origin, a
// second monitor to its LEFT (negative x), one ABOVE it and one BELOW it.
private let primaryMaxY: CGFloat = 1117
private let primaryScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
private let leftScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
private let aboveScreen = CGRect(x: 0, y: 1117, width: 1920, height: 1080)
private let belowScreen = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
private let allScreens = [primaryScreen, leftScreen, aboveScreen, belowScreen]

private var checksRun = 0
private var failures: [String] = []

private func check(_ name: String, _ passed: @autoclosure () -> Bool) {
    checksRun += 1
    if !passed() { failures.append(name) }
}

private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.0001) -> Bool {
    abs(a - b) <= tolerance
}

private func near(_ a: CGRect, _ b: CGRect) -> Bool {
    near(a.origin.x, b.origin.x) && near(a.origin.y, b.origin.y)
        && near(a.size.width, b.size.width) && near(a.size.height, b.size.height)
}

private func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
    near(a.x, b.x) && near(a.y, b.y)
}

// MARK: - Flip

private func testFlip() {
    // (name, AX rect, expected AppKit rect)
    let cases: [(String, CGRect, CGRect)] = [
        ("primary display",
         CGRect(x: 100, y: 50, width: 1, height: 17),
         CGRect(x: 100, y: 1050, width: 1, height: 17)),
        ("negative-origin screen to the left",
         CGRect(x: -1900, y: 600, width: 1, height: 17),
         CGRect(x: -1900, y: 500, width: 1, height: 17)),
        ("screen ABOVE the primary (negative AX y)",
         CGRect(x: 100, y: -400, width: 1, height: 17),
         CGRect(x: 100, y: 1500, width: 1, height: 17)),
        ("screen BELOW the primary (AX y past the pivot)",
         CGRect(x: 100, y: 1600, width: 1, height: 17),
         CGRect(x: 100, y: -500, width: 1, height: 17)),
    ]
    for (name, ax, expected) in cases {
        check("flip \(name)", near(CaretGeometry.flip(ax, primaryMaxY: primaryMaxY), expected))
        // The flip is its own inverse, which is what lets one pivot serve both directions.
        check("flip round-trips \(name)",
              near(CaretGeometry.flip(CaretGeometry.flip(ax, primaryMaxY: primaryMaxY), primaryMaxY: primaryMaxY), ax))
    }
    check("point flip",
          near(CaretGeometry.flip(CGPoint(x: 42, y: 117), primaryMaxY: primaryMaxY), CGPoint(x: 42, y: 1000)))
}

// MARK: - Rect validation

private func validate(_ rectAX: CGRect,
                      _ kind: CaretProbeKind,
                      element: CGRect?,
                      trustedLineHeight: CGFloat? = nil) -> CaretGeometry.ValidatedCaretRect? {
    CaretGeometry.validateAXCaretRect(rectAX, kind: kind, elementFrameAX: element,
                                      trustedLineHeight: trustedLineHeight,
                                      primaryMaxY: primaryMaxY, screens: allScreens)
}

private func testValidationRejects() {
    let field = CGRect(x: 50, y: 20, width: 600, height: 200)          // AX space
    let shortField = CGRect(x: 50, y: 20, width: 600, height: 40)
    let tallField = CGRect(x: 50, y: 20, width: 1400, height: 700)     // a slide / poster canvas
    let aboveField = CGRect(x: 50, y: -450, width: 600, height: 200)
    let belowField = CGRect(x: 50, y: 1550, width: 600, height: 200)
    let straddleField = CGRect(x: 50, y: -50, width: 600, height: 200)
    let farField = CGRect(x: 4900, y: 20, width: 600, height: 200)
    let leftField = CGRect(x: -1950, y: 550, width: 600, height: 200)

    // (name, AX rect, kind, element frame, trusted line height)
    let rejects: [(String, CGRect, CaretProbeKind, CGRect?, CGFloat?)] = [
        ("all-zero rect",
         CGRect(x: 0, y: 0, width: 0, height: 0), .collapsed, field, nil),
        // D2 regression: the classic AX garbage answer. The ORIGIN check has to run in AX
        // space — see testD2GarbageOriginMustBeCaughtBeforeTheFlip below.
        ("AX-space (0,0,1,20) garbage origin",
         CGRect(x: 0, y: 0, width: 1, height: 20), .collapsed, nil, nil),
        ("whole-element rect",
         shortField, .line, shortField, nil),
        // F4: a multi-line SELECTION rect. 300pt tall is past the absolute ceiling — a
        // line box that tall is not a line, whatever the app calls it.
        ("200x300 multi-line selection rect",
         CGRect(x: 100, y: 50, width: 200, height: 300), .glyph, tallField, nil),
        // F15: the width caps scale with the rect's own height, so what disqualifies a
        // paragraph rect is its ASPECT (width >> 1.5x height), not an absolute width.
        ("400x200 paragraph rect probed as a glyph",
         CGRect(x: 100, y: 30, width: 400, height: 200), .glyph, tallField, nil),
        ("300pt-wide rect probed as a glyph",
         CGRect(x: 100, y: 50, width: 300, height: 17), .glyph, field, nil),
        ("30pt-wide rect probed as a collapsed caret",
         CGRect(x: 100, y: 50, width: 30, height: 17), .collapsed, field, nil),
        ("NaN origin",
         CGRect(x: CGFloat.nan, y: 50, width: 1, height: 17), .collapsed, field, nil),
        ("NaN height",
         CGRect(x: 100, y: 50, width: 1, height: CGFloat.nan), .collapsed, field, nil),
        ("4pt line height (below the readable floor)",
         CGRect(x: 100, y: 50, width: 1, height: 4), .collapsed, field, nil),
        ("201pt line height (past the absolute ceiling)",
         CGRect(x: 100, y: 30, width: 1, height: 201), .collapsed, tallField, nil),
        ("outside every screen",
         CGRect(x: 5000, y: 50, width: 1, height: 17), .collapsed, farField, nil),
        // AppKit y 1105..1125 crosses the primary/above boundary at 1117.
        ("straddling two screens",
         CGRect(x: 100, y: -8, width: 1, height: 20), .collapsed, straddleField, nil),
        ("outside its element frame",
         CGRect(x: 900, y: 50, width: 1, height: 17), .collapsed, field, nil),
        ("above its element frame",
         CGRect(x: 100, y: -400, width: 1, height: 17), .collapsed, field, nil),
    ]
    for (name, rect, kind, element, line) in rejects {
        check("validate rejects \(name)", validate(rect, kind, element: element, trustedLineHeight: line) == nil)
    }

    // Sanity: the rejected-by-element-frame and rejected-by-screen cases are otherwise
    // fine, so the rejection really is the rule under test and not something incidental.
    check("validate accepts the above-screen caret with ITS element frame",
          validate(CGRect(x: 100, y: -400, width: 1, height: 17), .collapsed, element: aboveField) != nil)
    check("validate accepts the below-screen caret with ITS element frame",
          validate(CGRect(x: 100, y: 1600, width: 1, height: 17), .collapsed, element: belowField) != nil)
    check("validate accepts the left-screen caret with ITS element frame",
          validate(CGRect(x: -1900, y: 600, width: 1, height: 17), .collapsed, element: leftField) != nil)
}

private func testValidationAccepts() {
    let field = CGRect(x: 50, y: 20, width: 600, height: 200)
    guard let hit = validate(CGRect(x: 100, y: 50, width: 1, height: 17), .collapsed, element: field) else {
        check("validate accepts a normal caret inside its element", false)
        return
    }
    check("validate accepts a normal caret inside its element", true)
    check("accepted caret is flipped into AppKit space",
          near(hit.rectAppKit, CGRect(x: 100, y: 1050, width: 1, height: 17)))
    check("accepted caret reports the screen that fully contains it", hit.screenFrame == primaryScreen)

    // A single-glyph probe up to 24pt wide is legitimate (we only use its edge).
    check("validate accepts a 20pt glyph probe",
          validate(CGRect(x: 100, y: 50, width: 20, height: 17), .glyph, element: field) != nil)
    // A whole-line rect is legitimate for the line tier as long as it isn't the element.
    check("validate accepts a line rect narrower than its element",
          validate(CGRect(x: 60, y: 50, width: 400, height: 17), .line, element: field) != nil)
    // A trusted line height that AGREES widens nothing and rejects nothing.
    check("validate accepts a height consistent with the trusted line height",
          validate(CGRect(x: 100, y: 50, width: 1, height: 17), .collapsed, element: field, trustedLineHeight: 17) != nil)
    // With no element frame at all we still validate everything else.
    check("validate accepts with an unknown element frame",
          validate(CGRect(x: 100, y: 50, width: 1, height: 17), .collapsed, element: nil) != nil)
}

// The element frame is not a nicety: containment and the whole-element test are what make
// the aspect-ratio width caps safe, because a rect that lies about its own height buys
// itself a proportionally absurd width. Without a frame, a `.line` probe had NO width cap
// at all (the tier's cap is deliberately unbounded) and no containment check, so "the
// caret is here" could be answered with three paragraphs of a text view and be believed.
private func testProbesWithoutAnElementFrame() {
    let field = CGRect(x: 50, y: 20, width: 600, height: 400)

    // A line tier with no frame is simply not admissible.
    check("a 600x180 line rect with no element frame is rejected",
          validate(CGRect(x: 60, y: 40, width: 600, height: 180), .line, element: nil) == nil)
    check("even a plausibly-sized line rect is rejected with no element frame",
          validate(CGRect(x: 60, y: 40, width: 300, height: 17), .line, element: nil) == nil)

    // A line box may be tall (a heading) but it is ONE line: three lines of 17pt text is a
    // block, and the trusted line height is what says so.
    check("a 51pt (3-line) line rect inside its element is rejected against a 17pt line",
          validate(CGRect(x: 60, y: 40, width: 300, height: 51), .line,
                   element: field, trustedLineHeight: 17) == nil)
    check("…while one line of that element is accepted",
          validate(CGRect(x: 60, y: 40, width: 300, height: 17), .line,
                   element: field, trustedLineHeight: 17) != nil)
    check("with no trusted line height a line rect past 60pt is a block, not a line",
          validate(CGRect(x: 60, y: 40, width: 300, height: 61), .line, element: field) == nil)
    check("…and one just under it is still a line",
          validate(CGRect(x: 60, y: 40, width: 300, height: 59), .line, element: field) != nil)

    // Collapsed / glyph keep their tiers with no frame, but fall back to the strict
    // absolute caps: the aspect rule's floor stays (nothing that used to be accepted on an
    // ordinary line stops being accepted) and it gains the pre-aspect ceiling.
    check("a 150x190 collapsed rect with no element frame is rejected",
          validate(CGRect(x: 100, y: 30, width: 150, height: 190), .collapsed, element: nil) == nil)
    check("a 280x190 glyph rect with no element frame is rejected",
          validate(CGRect(x: 100, y: 30, width: 280, height: 190), .glyph, element: nil) == nil)
    check("a 30x100 collapsed rect with no element frame is rejected (past the 20pt ceiling)",
          validate(CGRect(x: 100, y: 30, width: 30, height: 100), .collapsed, element: nil) == nil)
    check("a 100pt-tall rect with no element frame is rejected outright",
          validate(CGRect(x: 100, y: 30, width: 1, height: 100), .collapsed, element: nil) == nil)
    check("…but the same rect inside a known element is still fine (F4 tall lines)",
          validate(CGRect(x: 100, y: 30, width: 1, height: 100), .collapsed, element: field) != nil)

    // The legitimate frameless answers still work — this is the tier AX-hostile hosts use.
    check("a hairline caret with no element frame is accepted",
          validate(CGRect(x: 100, y: 50, width: 1, height: 17), .collapsed, element: nil) != nil)
    check("a terminal cell with no element frame is accepted",
          validate(CGRect(x: 100, y: 50, width: 8, height: 17), .collapsed, element: nil) != nil)
    check("a 20pt glyph with no element frame is accepted",
          validate(CGRect(x: 100, y: 50, width: 20, height: 17), .glyph, element: nil) != nil)
    check("a big-font glyph with no element frame is accepted up to the 60pt ceiling",
          validate(CGRect(x: 100, y: 30, width: 55, height: 40), .glyph, element: nil) != nil)

    // The caps themselves, stated directly.
    check("the strict collapsed cap keeps the 4pt floor on a tiny line",
          near(CaretProbeKind.collapsed.strictMaxWidth(forHeight: 4), 4))
    check("the strict collapsed cap tracks the line until the 20pt ceiling",
          near(CaretProbeKind.collapsed.strictMaxWidth(forHeight: 17), 13.6))
    check("the strict collapsed cap stops at 20pt however tall the rect claims to be",
          near(CaretProbeKind.collapsed.strictMaxWidth(forHeight: 190), 20))
    check("the strict glyph cap keeps its 24pt floor",
          near(CaretProbeKind.glyph.strictMaxWidth(forHeight: 10), 24))
    check("the strict glyph cap stops at 60pt",
          near(CaretProbeKind.glyph.strictMaxWidth(forHeight: 190), 60))
    check("the line tier has no strict cap because it has no frameless form",
          near(CaretProbeKind.line.strictMaxWidth(forHeight: 17), 0))
}

// F4: a heading, a Keynote title or a zoomed-in document reports a line box far taller
// than any body text, and rejecting those rects outright meant the ghost simply never
// appeared where people write headlines. The rect is kept for POSITION; the ghost font is
// bounded elsewhere (28pt, testFontSizing) and the panel is anchored to the line's
// baseline (testPanelHeight), so a tall line costs nothing downstream.
private func testTallLinesAreUsable() {
    let slide = CGRect(x: 50, y: 20, width: 1400, height: 700)
    for height in [72.0, 90.0, 140.0, 200.0] as [CGFloat] {
        let rect = CGRect(x: 100, y: 30, width: 2, height: height)
        check("F4: a \(Int(height))pt line still yields a caret",
              validate(rect, .collapsed, element: slide) != nil)
        // …and never widens the ghost font past the 28pt cap.
        let sizing = CaretGeometry.ghostFontSizing(axFontPointSize: height * 0.8,
                                                   axFontHeight: height,
                                                   lineHeight: CaretGeometry.typographyLineHeight(height),
                                                   adjustment: 1)
        check("F4: a \(Int(height))pt line still caps the ghost font at 28",
              sizing.size <= CaretGeometry.maxFontSize + 0.0001)
    }
    check("F4: the typography line height is clamped even though the rect is not",
          near(CaretGeometry.typographyLineHeight(150), CaretGeometry.maxLineHeight))
    check("F4: an ordinary line passes typography clamping untouched",
          near(CaretGeometry.typographyLineHeight(17), 17))
}

// F5: the trusted-line-height window used to REJECT, and the trusted value was only ever
// refreshed by a successful probe — so one style change on a live element (a paragraph
// turned into a heading) locked the ghost out of that element permanently: every real rect
// failed the window, so the window never learned the new height. It now reports the
// disagreement instead of vetoing, and the caller overwrites the trusted value.
private func testTrustedLineHeightSelfHeals() {
    let field = CGRect(x: 50, y: 20, width: 600, height: 200)
    let heading = CGRect(x: 100, y: 50, width: 1, height: 40)   // was 17pt a keystroke ago
    guard let healed = validate(heading, .collapsed, element: field, trustedLineHeight: 17) else {
        check("F5: a restyled element is still placeable", false)
        return
    }
    check("F5: a restyled element is still placeable", true)
    check("F5: and the caller is told to overwrite the trusted line height", healed.lineHeightChanged)

    // The reverse direction (heading -> body) heals too.
    guard let shrunk = validate(CGRect(x: 100, y: 50, width: 1, height: 17), .collapsed,
                                element: field, trustedLineHeight: 40) else {
        check("F5: shrinking back to body text is placeable", false)
        return
    }
    check("F5: shrinking back to body text is placeable", true)
    check("F5: and is also flagged", shrunk.lineHeightChanged)

    // A height that AGREES is not flagged, so the log stays quiet in the common case.
    let agreeing = validate(CGRect(x: 100, y: 50, width: 1, height: 17), .collapsed,
                            element: field, trustedLineHeight: 17)
    check("F5: an agreeing height is not flagged", agreeing?.lineHeightChanged == false)

    // Self-healing is NOT a licence to accept garbage: every other check still runs.
    check("F5: garbage is still rejected regardless of the trusted height",
          validate(CGRect(x: 0, y: 0, width: 1, height: 40), .collapsed,
                   element: field, trustedLineHeight: 17) == nil)
}

// F15: the width caps are an aspect-ratio rule, not an absolute one. The old absolute caps
// (collapsed <= 4pt, glyph <= 24pt) rejected a block-cursor terminal's cell and any glyph
// above roughly a 30pt font, so neither ever got a ghost.
private func testWidthCapsScaleWithTheLine() {
    let field = CGRect(x: 50, y: 20, width: 600, height: 200)
    let slide = CGRect(x: 50, y: 20, width: 1400, height: 700)

    // (name, rect, kind, element, expected accept)
    let cases: [(String, CGRect, CaretProbeKind, CGRect, Bool)] = [
        ("hairline caret", CGRect(x: 100, y: 50, width: 1, height: 17), .collapsed, field, true),
        ("block-cursor cell on a 17pt line", CGRect(x: 100, y: 50, width: 8, height: 17), .collapsed, field, true),
        ("block-cursor cell on a 30pt line", CGRect(x: 100, y: 50, width: 15, height: 30), .collapsed, field, true),
        ("a cell wider than its own line", CGRect(x: 100, y: 50, width: 20, height: 17), .collapsed, field, false),
        ("a 24pt glyph", CGRect(x: 100, y: 50, width: 24, height: 17), .glyph, field, true),
        ("a 40pt emoji on a 30pt line", CGRect(x: 100, y: 50, width: 40, height: 30), .glyph, field, true),
        ("a 120pt glyph on a 90pt title line", CGRect(x: 100, y: 30, width: 120, height: 90), .glyph, slide, true),
        ("a paragraph rect at body size", CGRect(x: 100, y: 50, width: 300, height: 17), .glyph, field, false),
        ("a paragraph rect at title size", CGRect(x: 100, y: 30, width: 400, height: 90), .glyph, slide, false),
    ]
    for (name, rect, kind, element, expected) in cases {
        check("F15: \(name) is \(expected ? "accepted" : "rejected")",
              (validate(rect, kind, element: element) != nil) == expected)
    }

    // The collapsed floor never shrinks below the old absolute 4pt, so nothing that used
    // to be accepted on a tiny line stops being accepted.
    check("F15: the collapsed cap floors at 4pt", near(CaretProbeKind.collapsed.maxWidth(forHeight: 1), 4))
    check("F15: the glyph cap floors at 24pt", near(CaretProbeKind.glyph.maxWidth(forHeight: 1), 24))
    check("F15: a line probe has no width cap",
          CaretProbeKind.line.maxWidth(forHeight: 17) == .greatestFiniteMagnitude)

    // Which EDGE of a collapsed rect is the caret depends on what kind of answer it is: a
    // hairline's right edge is the caret, a terminal cell is the character the caret sits
    // ON, so there the caret is the cell's left edge.
    check("F15: a hairline caret uses its right edge",
          near(CaretGeometry.collapsedCaretX(in: CGRect(x: 100, y: 50, width: 1, height: 17)), 101))
    check("F15: a zero-width caret uses its right edge",
          near(CaretGeometry.collapsedCaretX(in: CGRect(x: 100, y: 50, width: 0, height: 17)), 100))
    check("F15: a 4pt caret is still a hairline",
          near(CaretGeometry.collapsedCaretX(in: CGRect(x: 100, y: 50, width: 4, height: 17)), 104))
    check("F15: an 8pt terminal cell uses its LEFT edge",
          near(CaretGeometry.collapsedCaretX(in: CGRect(x: 100, y: 50, width: 8, height: 17)), 100))
}

// F3: mirrored displays report the SAME frame twice. "More than one screen contains this
// rect" was treated as unresolvable ambiguity, so on a mirrored setup every single rect was
// rejected and the ghost never appeared at all.
private func testMirroredDisplays() {
    let mirrored = [primaryScreen, primaryScreen]
    let rect = CGRect(x: 100, y: 50, width: 1, height: 17)
    let hit = CaretGeometry.validateAXCaretRect(rect, kind: .collapsed, elementFrameAX: nil,
                                                trustedLineHeight: nil, primaryMaxY: primaryMaxY,
                                                screens: mirrored)
    check("F3: a mirrored display pair still resolves", hit != nil)
    check("F3: and resolves to that display", hit?.screenFrame == primaryScreen)

    // Three identical frames (mirroring onto two more displays) is the same situation.
    check("F3: three identical frames still resolve",
          CaretGeometry.validateAXCaretRect(rect, kind: .collapsed, elementFrameAX: nil,
                                            trustedLineHeight: nil, primaryMaxY: primaryMaxY,
                                            screens: [primaryScreen, primaryScreen, primaryScreen]) != nil)

    // Genuinely DIFFERENT overlapping frames are still ambiguous, and we still refuse to
    // guess which of them owns the caret.
    let overlapping = [primaryScreen, CGRect(x: -100, y: -100, width: 2000, height: 1400)]
    check("F3: two different overlapping frames are still rejected",
          CaretGeometry.validateAXCaretRect(rect, kind: .collapsed, elementFrameAX: nil,
                                            trustedLineHeight: nil, primaryMaxY: primaryMaxY,
                                            screens: overlapping) == nil)
    check("F3: no screen at all is still rejected",
          CaretGeometry.validateAXCaretRect(rect, kind: .collapsed, elementFrameAX: nil,
                                            trustedLineHeight: nil, primaryMaxY: primaryMaxY,
                                            screens: []) == nil)
}

// F9/F10: a fix whose point is our own forward guess — a cached fix shifted by
// advanceGhost, or a probe whose backward-snap guard handed back the optimistic point —
// must not read as authoritative. The settle path calibrates the per-app width EMA only
// against an authoritative point, and calibrating against advanceGhost's own output taught
// the model nothing but its own bias.
private func testExtrapolatedFixesAreNotAuthoritative() {
    func fix(_ path: CaretLadderPath, extrapolated: Bool) -> CaretFix {
        CaretFix(pointAppKit: NSPoint(x: 100, y: 200), lineHeight: 17,
                 font: NSFont.systemFont(ofSize: 13), color: .black,
                 screenFrame: primaryScreen, elementFrameAX: nil, path: path,
                 at: Date(), extrapolated: extrapolated)
    }
    for path in [CaretLadderPath.marker, .bounds, .line] {
        check("F9: a probed .\(path.rawValue) fix is authoritative", fix(path, extrapolated: false).isAuthoritative)
        check("F9: an extrapolated .\(path.rawValue) fix is NOT authoritative",
              !fix(path, extrapolated: true).isAuthoritative)
    }
    for path in [CaretLadderPath.click, .ocr] {
        check("F9: a .\(path.rawValue) anchor is never authoritative", !fix(path, extrapolated: false).isAuthoritative)
    }
    // The default keeps every existing construction site honest.
    check("F9: extrapolated defaults to false",
          CaretFix(pointAppKit: .zero, lineHeight: 17, font: NSFont.systemFont(ofSize: 13),
                   color: .black, screenFrame: primaryScreen, elementFrameAX: nil,
                   path: .bounds, at: Date()).isAuthoritative)
}

// D2 regression, stated explicitly: the old code flipped FIRST and then checked for a
// (0,0) origin, so AX-space garbage arrived at the check looking like a perfectly ordinary
// rect near the top of the primary display — and the ghost landed there, thousands of
// times per session.
private func testD2GarbageOriginMustBeCaughtBeforeTheFlip() {
    let garbageAX = CGRect(x: 0, y: 0, width: 1, height: 20)
    let flipped = CaretGeometry.flip(garbageAX, primaryMaxY: primaryMaxY)
    check("D2: flipped AX garbage no longer looks like garbage", flipped.origin != .zero)
    check("D2: flipped AX garbage would have landed on the primary display",
          primaryScreen.contains(flipped))
    check("D2: validation rejects it anyway (checked in AX space)",
          validate(garbageAX, .collapsed, element: nil) == nil)
}

// MARK: - Ghost font sizing

private func testFontSizing() {
    // (name, AX point size, AX font line box, measured line height, per-app adjustment,
    //  expected trust, assertion on the resulting size)
    let cases: [(String, CGFloat?, CGFloat?, CGFloat, CGFloat, Bool, (CGFloat) -> Bool)] = [
        // D1 regression: a Notion H1 reports a 48pt font for an 18pt caret line. The font
        // describes the block, not the run at the caret; believing it produced 48pt ghost
        // text that then poisoned the whole app via the per-bundle cache.
        ("D1: 48pt font on an 18pt line is distrusted", 48, 56, 18, 1.0, false, { $0 <= 24.3 }),
        ("ordinary 13pt font on a 17pt line is trusted", 13, 16, 17, 1.0, true, { near($0, 13) }),
        ("a 3x per-app adjustment cannot exceed 1.35x the line", 13, 16, 17, 3.0, true,
         { $0 <= min(28, 17 * 1.35) + 0.0001 }),
        ("no AX font falls back to 0.62x the line", nil, nil, 20, 1.0, false, { near($0, 12.4) }),
        ("a tiny line still clears the readability floor", 6, 7, 6, 1.0, true, { $0 >= 8 }),
        ("a huge line is capped at 28pt", 40, 44, 60, 1.0, true, { near($0, 28) }),
        ("a 0.5x per-app adjustment scales down", 20, 23, 20, 0.5, true, { near($0, 10) }),
        ("a nonsensical adjustment is ignored", 13, 16, 17, 0, true, { near($0, 13) }),
    ]
    for (name, point, height, line, adjust, expectTrust, sizeOK) in cases {
        let sizing = CaretGeometry.ghostFontSizing(axFontPointSize: point, axFontHeight: height,
                                                   lineHeight: line, adjustment: adjust)
        check("font sizing trust: \(name)", sizing.trusted == expectTrust)
        check("font sizing size: \(name) (got \(sizing.size))", sizeOK(sizing.size))
        check("font sizing never exceeds 1.35x the line: \(name)",
              sizing.size <= max(9, min(28, line * 1.35)) + 0.0001)
    }

}

// The panel's origin is the caret LINE's bottom and it grows upward, and GhostView centres
// the text box inside it — so the panel height is a baseline control: the ghost's baseline
// lands at (panelHeight/2 - 0.39 * fontSize) above the line bottom. The host's own baseline
// sits ~0.21 of the line box above that same bottom edge. These tests assert that the two
// coincide, which is the property the old "line height clamped to 40" rule lost the moment
// the line grew past 40pt (a Keynote title's ghost sat ~16pt below its baseline).
private func testPanelHeight() {
    func ghostBaseline(line: CGFloat, fontSize: CGFloat) -> CGFloat {
        CaretGeometry.panelHeight(forLineHeight: line, fontSize: fontSize) / 2 - 0.39 * fontSize
    }
    func hostBaseline(line: CGFloat) -> CGFloat { 0.21 * line }

    // (line height, the size the ghost will actually be drawn at)
    let cases: [(CGFloat, CGFloat)] = [(17, 13), (20, 12.4), (40, 24.8), (72, 28), (150, 28), (200, 28)]
    for (line, size) in cases {
        check("panel puts the ghost on the host's baseline (line \(Int(line)))",
              near(ghostBaseline(line: line, fontSize: size), hostBaseline(line: line), 0.5))
    }

    // Ordinary text is unchanged in practice: the old rule said "the line height", and the
    // baseline rule independently arrives within a point of it.
    check("panel on a 17pt line still matches the old line-height rule",
          abs(CaretGeometry.panelHeight(forLineHeight: 17, fontSize: 13) - 17) <= 1)
    // A tall line gets a tall panel instead of a 40pt one wedged at the bottom of it.
    check("panel grows with a 72pt heading line",
          CaretGeometry.panelHeight(forLineHeight: 72) > 40)
    check("panel grows with a 150pt title line",
          CaretGeometry.panelHeight(forLineHeight: 150) > CaretGeometry.panelHeight(forLineHeight: 72))
    // Floors and bounds.
    check("panel height floors at 12", near(CaretGeometry.panelHeight(forLineHeight: 6), 12))
    check("panel height floors at 12 for a nonsense line",
          near(CaretGeometry.panelHeight(forLineHeight: .nan), CaretGeometry.panelHeight(forLineHeight: 18)))
    check("panel height stays bounded for an absurd line",
          CaretGeometry.panelHeight(forLineHeight: 100_000) <= 0.42 * CaretGeometry.maxCaretRectHeight
              + 0.78 * CaretGeometry.maxFontSize + 0.0001)
    // Omitting the font size predicts it from the line, within a point or two of the truth.
    check("panel height without a font size predicts it from the line",
          abs(CaretGeometry.panelHeight(forLineHeight: 20)
              - CaretGeometry.panelHeight(forLineHeight: 20, fontSize: 12.4)) <= 2)
    check("panel height ignores a nonsense font size",
          near(CaretGeometry.panelHeight(forLineHeight: 20, fontSize: .nan),
               CaretGeometry.panelHeight(forLineHeight: 20)))
}

// MARK: - Screen selection

private func testScreenSelection() {
    let twoMonitors = [primaryScreen, leftScreen]   // primary FIRST, as NSScreen.screens reports it
    // D6 regression: a caret at the right edge of the LEFT display. The old code picked
    // the screen by intersecting the up-to-760pt-wide ghost FRAME, which reached into the
    // primary display and sent the ghost to the wrong monitor.
    let caret = CGPoint(x: -1, y: 500)
    check("D6: caret at the left display's right edge resolves to the LEFT screen",
          CaretGeometry.screenContaining(point: caret, in: twoMonitors) == leftScreen)
    let ghostFrame = CGRect(x: caret.x, y: caret.y, width: 760, height: 20)
    check("D6: the old frame-intersection heuristic would have picked the primary",
          twoMonitors.first(where: { $0.intersects(ghostFrame) }) == primaryScreen)

    let cases: [(String, CGPoint, CGRect?)] = [
        ("middle of the primary", CGPoint(x: 800, y: 500), primaryScreen),
        ("middle of the left monitor", CGPoint(x: -900, y: 500), leftScreen),
        ("on the screen above", CGPoint(x: 800, y: 1500), aboveScreen),
        ("on the screen below", CGPoint(x: 800, y: -500), belowScreen),
        ("far off every display", CGPoint(x: 9000, y: 9000), nil),
        ("NaN", CGPoint(x: CGFloat.nan, y: 500), nil),
    ]
    for (name, point, expected) in cases {
        check("screenContaining \(name)", CaretGeometry.screenContaining(point: point, in: allScreens) == expected)
    }
    check("screenContaining with no screens at all",
          CaretGeometry.screenContaining(point: CGPoint(x: 0, y: 0), in: []) == nil)
}

// MARK: - Ghost clamping

private func testGhostClamping() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = screen.insetBy(dx: 8, dy: 8)

    // (name, requested ghost frame)
    let cases: [(String, CGRect)] = [
        ("ghost wider than the remaining room", CGRect(x: 1300, y: 400, width: 760, height: 20)),
        ("ghost wider than the whole screen", CGRect(x: 20, y: 400, width: 2000, height: 20)),
        ("ghost at the very top of the screen", CGRect(x: 100, y: 895, width: 300, height: 20)),
        ("ghost at the very bottom of the screen", CGRect(x: 100, y: -20, width: 300, height: 20)),
        ("ghost that already fits", CGRect(x: 100, y: 400, width: 300, height: 20)),
    ]
    for (name, requested) in cases {
        let clamped = CaretGeometry.clampGhostFrame(requested, toScreen: screen)
        check("clamp keeps \(name) inside the screen",
              clamped.minX >= visible.minX - 0.0001 && clamped.maxX <= visible.maxX + 0.0001
                  && clamped.minY >= visible.minY - 0.0001 && clamped.maxY <= visible.maxY + 0.0001)
        // The frame's x IS the caret: a ghost that doesn't fit is truncated, never walked
        // back over the text the user is typing.
        check("clamp never moves \(name) left of the caret", clamped.minX >= requested.minX - 0.0001)
    }

    let tight = CaretGeometry.clampGhostFrame(CGRect(x: 1300, y: 400, width: 760, height: 20), toScreen: screen)
    check("clamp truncates the width instead of shifting x", near(tight.minX, 1300))
    check("clamp truncates to exactly the room available", near(tight.width, visible.maxX - 1300))

    let fits = CaretGeometry.clampGhostFrame(CGRect(x: 100, y: 400, width: 300, height: 20), toScreen: screen)
    check("clamp leaves a ghost that already fits alone", near(fits, CGRect(x: 100, y: 400, width: 300, height: 20)))
}

// MARK: - Budgets

private func testExtrapolationBudget() {
    // (name, age, chars typed since the fix, line changes, expected)
    let cases: [(String, TimeInterval, Int, Int, Bool)] = [
        ("fresh fix", 0, 0, 0, true),
        ("just inside the age budget", 0.6, 10, 0, true),
        ("just outside the age budget", 0.601, 10, 0, false),
        ("exactly at the character budget", 0.1, 40, 0, true),
        ("one character past the budget", 0.1, 41, 0, false),
        ("a single line change ends it immediately", 0.1, 1, 1, false),
        ("a clock that went backwards", -1, 0, 0, false),
    ]
    for (name, age, chars, lines, expected) in cases {
        check("extrapolation budget: \(name)",
              CaretGeometry.extrapolationWithinBudget(age: age, chars: chars, lineChanges: lines) == expected)
    }
}

private func testClickAnchorBudget() {
    // (name, age, chars, newline, anchor x, advance, element right edge, expected)
    let cases: [(String, TimeInterval, Int, Bool, CGFloat, CGFloat, CGFloat?, Bool)] = [
        ("fresh click", 1, 5, false, 200, 30, 900, true),
        ("just inside the age budget", 20, 5, false, 200, 30, 900, true),
        ("past the age budget", 20.1, 5, false, 200, 30, 900, false),
        ("exactly at the character budget", 1, 80, false, 200, 30, 900, true),
        ("past the character budget", 1, 81, false, 200, 30, 900, false),
        ("a newline since the click", 1, 5, true, 200, 30, 900, false),
        ("advance about to pass the field's right edge (soft wrap)", 1, 5, false, 200, 700, 900, false),
        ("advance just inside the field's right edge", 1, 5, false, 200, 691, 900, true),
        ("unknown field width keeps the anchor", 1, 5, false, 200, 5000, nil, true),
    ]
    for (name, age, chars, newline, anchorX, advance, maxX, expected) in cases {
        check("click anchor budget: \(name)",
              CaretGeometry.clickAnchorUsable(age: age, chars: chars, containsNewline: newline,
                                              anchorX: anchorX, advance: advance,
                                              elementMaxX: maxX) == expected)
    }
}

@main
struct CaretTests {
    static func main() {
        testFlip()
        testValidationRejects()
        testValidationAccepts()
        testProbesWithoutAnElementFrame()
        testD2GarbageOriginMustBeCaughtBeforeTheFlip()
        testTallLinesAreUsable()
        testTrustedLineHeightSelfHeals()
        testWidthCapsScaleWithTheLine()
        testMirroredDisplays()
        testExtrapolatedFixesAreNotAuthoritative()
        testFontSizing()
        testPanelHeight()
        testScreenSelection()
        testGhostClamping()
        testExtrapolationBudget()
        testClickAnchorBudget()

        if failures.isEmpty {
            print("caret geometry: \(checksRun) checks passed")
            exit(0)
        }
        print("caret geometry: \(failures.count) of \(checksRun) checks FAILED")
        for failure in failures { print("  FAIL  \(failure)") }
        exit(1)
    }
}
