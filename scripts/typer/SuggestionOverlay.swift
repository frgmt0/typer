import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Named correction colors (#8, spec E §8). Mirrors Cotypist's asset colors
// `autocorrectStrikethroughRed` / `autocorrectCorrectionGreen`: the typo is struck through in
// red, the suggested fix drawn in green right after it. Kept as one place so the overlay and
// any future candidate picker render the diff identically. Dynamic so they read correctly in
// light and dark appearances.
enum CorrectionColors {
    static let strikethroughRed = NSColor(name: "autocorrectStrikethroughRed") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.16, blue: 0.13, alpha: 1)
    }
    static let correctionGreen = NSColor(name: "autocorrectCorrectionGreen") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.86, blue: 0.50, alpha: 1)
            : NSColor(srgbRed: 0.13, green: 0.62, blue: 0.30, alpha: 1)
    }
    // Advisory grammar notes (no machine-applicable fix): amber, distinct from a real fix.
    static let advisoryAmber = NSColor.systemOrange
}

final class SuggestionOverlay: NSPanel {
    private let ghost = GhostView(frame: NSRect(x: 0, y: 0, width: 420, height: 38))
    // The widest the ghost may ever be. Clamped to the screen on top of this.
    private let maxGhostWidth: CGFloat = 760

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 38),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        contentView = ghost
        orderOut(nil)
    }

    // The caret fix carries the font, colour, line height and the caret point; the overlay
    // holds no typography state of its own. (A stashed host font used to win over the
    // clamped fallback unconditionally, so a single bad AX font read produced a 48pt ghost
    // for the rest of the session.)
    func showCompletion(_ text: String, at fix: CaretFix, animate: Bool) {
        let attr = NSAttributedString(string: text, attributes: [
            .font: fix.font, .foregroundColor: fix.color.withAlphaComponent(0.5)])
        place(attr, font: fix.font, at: fix, shimmer: animate)
    }

    // Inline diff for a pending correction. Spelling, and grammar with a fix, render the
    // red-strike original → green replacement. Advisory-only grammar (no replacement)
    // shows just its message in amber — Tab passes through, there's nothing to apply.
    // The diff is always drawn in the system font (a diff arrow in a condensed host font
    // is unreadable) but at the caret's clamped size.
    func show(correction c: Correction, at fix: CaretFix) {
        let fs = fix.font.pointSize
        let s = NSMutableAttributedString()
        if let replacement = c.replacement {
            // Typo struck through in red, fix in green right after — the named-color diff (#8).
            s.append(NSAttributedString(string: c.displayOriginal, attributes: [
                .font: NSFont.systemFont(ofSize: fs),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: CorrectionColors.strikethroughRed,
                .foregroundColor: CorrectionColors.strikethroughRed.withAlphaComponent(0.75)]))
            s.append(NSAttributedString(string: " → " + replacement, attributes: [
                .font: NSFont.systemFont(ofSize: fs, weight: .semibold),
                .foregroundColor: CorrectionColors.correctionGreen]))
        } else {
            // Advisory-only grammar note: amber, no green replacement glyph.
            s.append(NSAttributedString(string: c.message ?? c.displayOriginal, attributes: [
                .font: NSFont.systemFont(ofSize: fs, weight: .medium),
                .foregroundColor: CorrectionColors.advisoryAmber.withAlphaComponent(0.95)]))
        }
        place(s, font: NSFont.systemFont(ofSize: fs), at: fix, shimmer: true)
    }

    // `fix.pointAppKit` is the caret's right edge (x) and line bottom (y). The panel is
    // the caret line height, so the text is vertically centered on the caret line (inline).
    //
    // The screen is chosen by the caret POINT — never by intersecting the (up to 760pt
    // wide) ghost frame, which made the ghost hop to the neighbouring display, and never
    // NSScreen.main, which is "wherever the key window is". No screen owns the point =>
    // we do not know where this belongs, so nothing is drawn.
    private func place(_ attr: NSAttributedString, font: NSFont, at fix: CaretFix, shimmer: Bool) {
        let screens = NSScreen.screens
        guard let hit = CaretGeometry.screenContaining(point: fix.pointAppKit, in: screens.map(\.frame)),
              let screen = screens.first(where: { $0.frame == hit }) else { orderOut(nil); return }
        let taperW: CGFloat = 20
        let textW = ceil(attr.size().width)
        let requested = NSRect(x: fix.pointAppKit.x, y: fix.pointAppKit.y,
                               width: min(textW + 8, maxGhostWidth),
                               height: CaretGeometry.panelHeight(forLineHeight: fix.lineHeight, fontSize: fix.font.pointSize))
        // Truncate to fit, never shift left over the text the user is typing.
        let frame = CaretGeometry.clampGhostFrame(requested, toScreen: screen.visibleFrame)
        guard frame.width >= 12, frame.height >= 8 else { orderOut(nil); return }
        let wasVisible = isVisible
        // Follow the display the ghost actually lands on: a scale fixed at construction
        // renders blurry (or oversampled) text on every other monitor.
        ghost.setContentsScale(screen.backingScaleFactor)
        setFrame(frame, display: true)
        ghost.frame = NSRect(origin: .zero, size: frame.size)
        // Shimmer only on a genuinely fresh appearance — never while streaming updates
        // or shrinking as the user types through it.
        ghost.render(attr, font: font, taperWidth: taperW, shimmer: shimmer && !wasVisible)
        if !wasVisible {
            ghost.fadeIn()
            orderFrontRegardless()
        }
    }
}
