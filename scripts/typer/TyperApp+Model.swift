import AppKit
import Foundation

// Model-size switching (small typer-1 race ⇄ large typer-1l) at runtime: swap the ModelRouter
// in place, tearing down the old helper processes, with no app restart. The large model is
// fetched on demand the first time it's chosen.
extension TyperApp {
    // Human-facing labels for the two variants (menu + onboarding).
    static let smallVariantLabel = "Small · typer-1 (0.6B)"
    static let largeVariantLabel = "Large · typer-1l (1.2 GB)"

    // Rebuild the router from the current cfg and warm it. Main-thread only (router is
    // main-thread state). The previous router's helper processes are killed after the swap so
    // the next generation spawns against the newly chosen model.
    func reloadModel() {
        let old = router
        router = ModelRouter(cfg: cfg)
        routedModelName = router.defaultName
        old?.shutdown()
        clearSuggestion()                       // any in-flight suggestion belonged to the old model
        if cfg.enabled, cfg.completionEnabled {
            DispatchQueue.global(qos: .utility).async { self.router.warmUp() }
        }
        updateStatusTitle()
        log("model reloaded: variant=\(cfg.modelVariant) serving=\(router.defaultName) large=\(router.isLarge)")
    }

    // Switch the user's model choice. Picking "large" when it isn't downloaded yet kicks off the
    // on-demand fetch and switches once it lands; the menu shows progress via ModelDownloader.
    func setModelVariant(_ variant: String) {
        let v = (variant == "large") ? "large" : "small"
        guard v != cfg.modelVariant else { return }
        if v == "large", !ModelRouter.largeModelInstalled() {
            log("large model not present — downloading from \(ModelRouter.largeModelURL)")
            let dest = URL(fileURLWithPath: ModelRouter.largeModelPath)
            ModelDownloader.shared.download(urlString: ModelRouter.largeModelURL, to: dest) { [weak self] ok in
                guard let self else { return }
                if ok {
                    log("large model downloaded -> \(ModelRouter.largeModelPath)")
                    self.applyVariant("large")
                } else {
                    log("large model download failed")
                }
            }
            return
        }
        applyVariant(v)
    }

    private func applyVariant(_ variant: String) {
        cfg.modelVariant = variant
        writeConfig("model_variant", variant)
        reloadModel()
    }

    // The variant currently being SERVED (falls back to small if large was chosen but isn't
    // installed) — what the menu's selected row should reflect.
    func effectiveVariant() -> String {
        (cfg.modelVariant == "large" && ModelRouter.largeModelInstalled()) ? "large" : "small"
    }
}
