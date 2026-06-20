import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import SwiftUI

// First-launch onboarding: a small multi-step window (welcome → permissions → model choice →
// how-to) shown once, until cfg.onboardingComplete. The app is an .accessory (menu-bar) app, so
// we activate it to bring the window forward. Permission status is polled live so the dots flip
// the moment the user grants in System Settings, without them returning to the app.

final class OnboardingModel: ObservableObject {
    weak var app: TyperApp?
    @Published var step = 0
    @Published var axTrusted = false
    @Published var screenGranted = false
    @Published var modelVariant = "small"
    var onFinish: (() -> Void)?

    private var timer: Timer?
    let lastStep = 3

    func start() {
        refreshPerms()
        modelVariant = app?.effectiveVariant() ?? "small"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPerms() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refreshPerms() {
        axTrusted = AXIsProcessTrusted()
        screenGranted = CGPreflightScreenCaptureAccess()
    }

    func next() { if step < lastStep { step += 1 } }
    func back() { if step > 0 { step -= 1 } }

    func promptAccessibility() {
        app?.promptAccessibility()
        openSettings("Privacy_Accessibility")
    }
    func requestScreen() {
        CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
    }
    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func pickModel(_ v: String) {
        modelVariant = v
        app?.setModelVariant(v)         // triggers the on-demand download for "large"
    }

    func finish() { stop(); onFinish?() }
}

// Owns the onboarding NSWindow. `TyperApp.showOnboarding()` builds and presents it.
final class OnboardingController {
    private var window: NSWindow?
    let model = OnboardingModel()

    func show(app: TyperApp) {
        model.app = app
        model.onFinish = { [weak self] in self?.close() }
        model.start()

        let host = NSHostingController(rootView: OnboardingView(model: model))
        let win = NSWindow(contentViewController: host)
        win.title = "Welcome to Typer"
        win.styleMask = [.titled, .closable]
        win.isMovableByWindowBackground = true
        win.setContentSize(NSSize(width: 460, height: 560))
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }
}

extension TyperApp {
    func showOnboarding() {
        let controller = OnboardingController()
        onboarding = controller
        controller.model.onFinish = { [weak self] in
            guard let self else { return }
            self.cfg.onboardingComplete = true
            self.writeConfig("onboarding_complete", "true")
            self.onboarding?.close()
            self.onboarding = nil
            log("onboarding complete")
        }
        controller.show(app: self)
    }
}

// MARK: - View

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var downloader = ModelDownloader.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { content.padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 12) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.4)
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 460, height: 560)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case 0: welcome
        case 1: permissions
        case 2: modelChoice
        default: howto
        }
    }

    // Step 0 — welcome
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "keyboard").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Inline autocomplete, on your Mac.").font(.system(size: 22, weight: .bold))
            Text("Typer suggests the next few words as grey ghost text in any text field — chat, email, code, notes. Everything runs **on-device**; your typing never leaves your machine.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            bullet("Tab accepts one word · ` accepts all · Esc dismisses")
            bullet("Learns your style + vocabulary, locally")
            bullet("Pick a model size that fits your Mac (next steps)")
        }
    }

    // Step 1 — permissions
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Permissions").font(.system(size: 22, weight: .bold))
            permRow(granted: model.axTrusted, required: true,
                    title: "Accessibility", why: "Lets Typer read the text you're typing and insert accepted suggestions. Required.",
                    action: { model.promptAccessibility() })
            permRow(granted: model.screenGranted, required: false,
                    title: "Screen Recording", why: "Optional — only for caret placement in terminals and on-screen context. Everything else works without it.",
                    action: { model.requestScreen() })
            if !model.axTrusted {
                Text("After enabling Typer in System Settings, this updates automatically.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // Step 2 — model choice
    private var modelChoice: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your model").font(.system(size: 22, weight: .bold))
            Text("You can change this any time from the menu-bar icon.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            modelOption(v: "small", title: "Small — typer-1 (0.6B)",
                        desc: "Fast and light, runs on any Mac. The default. ~0.6 GB.")
            modelOption(v: "large", title: "Large — typer-1l (1.2 GB)",
                        desc: "Higher-quality suggestions for Macs with RAM to spare (16 GB+). Downloads once when selected.")
            if case let .downloading(frac) = downloader.state {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: frac >= 0 ? frac : nil, total: 1).tint(.accentColor)
                    Text(frac >= 0 ? "Downloading typer-1l… \(Int(frac * 100))%  (~1.2 GB)" : "Downloading typer-1l…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.top, 2)
            } else if case let .failed(msg) = downloader.state {
                Text("Download failed — \(msg). You can retry from the menu.")
                    .font(.system(size: 11)).foregroundStyle(.red)
            } else if model.modelVariant == "large", ModelRouter.largeModelInstalled() {
                Text("Large model ready.").font(.system(size: 11)).foregroundStyle(.green)
            }
        }
    }

    // Step 3 — how to use
    private var howto: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text("You're set.").font(.system(size: 22, weight: .bold))
            Text("Start typing in any text field — a grey suggestion appears at your cursor.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                keycap("Tab", "accept the next word")
                keycap("`", "accept the whole suggestion")
                keycap("Esc", "dismiss it")
            }
            Text("The ⌨︎ menu-bar icon has everything: toggles, model size, stats, and updates.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // footer: back · step dots · next / get started
    private var footer: some View {
        HStack {
            if model.step > 0 {
                Button("Back") { model.back() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0...model.lastStep, id: \.self) { i in
                    Circle().fill(i == model.step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            Button(model.step == model.lastStep ? "Get Started" : "Next") {
                if model.step == model.lastStep { model.finish() } else { model.next() }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: pieces

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.tint).padding(.top, 2)
            Text(s).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permRow(granted: Bool, required: Bool, title: String, why: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(granted ? Color.green : (required ? Color.orange : Color.secondary.opacity(0.4)))
                .frame(width: 10, height: 10).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(required ? "required" : "optional").font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("Granted").font(.system(size: 11)).foregroundStyle(.green)
            } else {
                Button("Enable") { action() }
            }
        }
    }

    private func modelOption(v: String, title: String, desc: String) -> some View {
        let active = model.modelVariant == v
        return Button(action: { model.pickModel(v) }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: active ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16)).foregroundStyle(active ? Color.accentColor : Color.secondary).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Text(desc).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(active ? 0.06 : 0.02)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func keycap(_ key: String, _ desc: String) -> some View {
        HStack(spacing: 10) {
            Text(key).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            Text(desc).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
