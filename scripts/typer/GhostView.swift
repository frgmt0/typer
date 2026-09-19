import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Layer-based ghost renderer: SF system font, a soft trailing taper (the text fades
// at its right edge), and a one-shot shimmer sweep + fade-in when a fresh suggestion
// appears (but not while typing through it).
final class GhostView: NSView {
    private let textLayer = CATextLayer()
    private let shimmer = CAGradientLayer()
    private let shimmerMask = CATextLayer()
    private let taper = CAGradientLayer()
    private let inset: CGFloat = 3

    override init(frame: NSRect) { super.init(frame: frame); build() }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    private func build() {
        wantsLayer = true
        let root = CALayer()
        layer = root
        // Deliberately NOT NSScreen.main: the ghost follows the caret across displays, so
        // the scale is set per placement from the screen it actually lands on (see
        // setContentsScale). 2 is only the pre-first-placement default.
        for tl in [textLayer, shimmerMask] {
            tl.contentsScale = 2; tl.truncationMode = .none; tl.isWrapped = false; tl.alignmentMode = .left
        }
        root.addSublayer(textLayer)

        shimmer.startPoint = CGPoint(x: 0, y: 0.5); shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.6).cgColor, NSColor.clear.cgColor]
        shimmer.mask = shimmerMask
        shimmer.isHidden = true
        root.addSublayer(shimmer)

        // Trailing taper: a gradient mask that softens the last ~20px of the ghost.
        taper.startPoint = CGPoint(x: 0, y: 0.5); taper.endPoint = CGPoint(x: 1, y: 0.5)
        taper.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.35).cgColor]
        root.mask = taper
    }

    // Match the backing store to the display the ghost is about to appear on. Called from
    // SuggestionOverlay.place on every placement; a no-op when the scale hasn't changed.
    func setContentsScale(_ scale: CGFloat) {
        let s = scale.isFinite && scale > 0 ? scale : 2
        guard textLayer.contentsScale != s else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        textLayer.contentsScale = s
        shimmerMask.contentsScale = s
        layer?.contentsScale = s
        CATransaction.commit()
    }

    // `font` is the host field's real font (spec B.2) when known, else a system font; it
    // is used for the shimmer mask so the sweep matches the rendered ghost typography.
    func render(_ attr: NSAttributedString, font: NSFont, taperWidth: CGFloat, shimmer doShimmer: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)   // no implicit anim on text/move
        let h = ceil(attr.size().height)
        let f = CGRect(x: inset, y: (bounds.height - h) / 2, width: max(0, bounds.width - inset), height: h)
        textLayer.string = attr
        textLayer.frame = f
        taper.frame = bounds
        let fadeStart = bounds.width > taperWidth ? (bounds.width - taperWidth) / bounds.width : 0.55
        taper.locations = [0, NSNumber(value: Double(fadeStart)), 1.0]
        CATransaction.commit()
        if doShimmer { runShimmer(text: attr.string, font: font, frame: f) } else { shimmer.isHidden = true }
    }

    private func runShimmer(text: String, font: NSFont, frame f: CGRect) {
        shimmer.isHidden = false
        shimmer.frame = bounds
        shimmerMask.string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.white])
        shimmerMask.frame = f
        shimmer.locations = [1.0, 1.0, 1.0]   // settle: band swept off the right edge
        let band = CABasicAnimation(keyPath: "locations")
        band.fromValue = [-0.6, -0.3, 0.0]
        band.toValue = [1.0, 1.3, 1.6]
        band.duration = 0.6
        band.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.shimmer.isHidden = true }
        shimmer.add(band, forKey: "shimmer")
        CATransaction.commit()
    }

    func fadeIn() {
        guard let root = layer else { return }
        let group = CAAnimationGroup()
        let op = CABasicAnimation(keyPath: "opacity"); op.fromValue = 0.0; op.toValue = 1.0
        let mv = CABasicAnimation(keyPath: "transform.translation.y"); mv.fromValue = -2.0; mv.toValue = 0.0
        group.animations = [op, mv]; group.duration = 0.14
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(group, forKey: "in")
    }
}
