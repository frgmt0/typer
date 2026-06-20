import AppKit
import SwiftUI

// Custom menu-bar dropdown. Replaces the stock NSMenu with a SwiftUI popover so the panel can
// look like something we designed: a status dot, a model-preference bar, real switch toggles,
// and the rarely-touched controls tucked into collapsible sections instead of a flat wall of
// rows. The app stays the source of truth — MenuModel just snapshots state on open and routes
// toggles/actions back to TyperApp.
//
// Layout note: every row is an explicit HStack with a leading label and a trailing control,
// sharing one horizontal inset, so switches line up perfectly. No GeometryReader anywhere —
// inside an auto-sizing NSPopover it reports an ambiguous size and beachballs the host.

private let kInset: CGFloat = 16
private let kWidth: CGFloat = 300
private let kBarWidth: CGFloat = kWidth - kInset * 2

// What the popover renders, snapshotted from TyperApp each time it opens.
struct MenuSnapshot {
    var enabled = true
    var completionEnabled = true
    var typoEnabled = false

    var hasCurrentApp = false
    var currentAppName = ""
    var currentAppDisabled = false
    var disableInTerminals = false
    var batterySaver = false
    var batteryThrottling = false

    var windowContext = false
    var clipboardContext = false
    var screenContext = false
    var screenshotCaret = false
    var topicMemory = false
    var topicCount = 0
    var styleMemory = false
    var lexicon = false
    var adaptive = false

    var trainingEnabled = false
    var trainingCount = 0

    var racing = false
    var aName = "a"
    var bName = "b"
    var aShare = 0.5
    var aReward = 0.0
    var bReward = 0.0
    var lockedName: String?
    var singleModel = ""

    var statsLine1 = ""
    var statsLine2 = ""

    var version = ""              // short git commit this build was made from ("" if unknown)
    var canUpdate = false         // true only for source builds that know their checkout path

    var modelVariant = "small"    // "small" | "large" — the size currently being served
    var largeInstalled = false    // whether typer-1l.gguf is already downloaded
}

enum MenuAction {
    case config, log, inspectTraining, resetRace, clearStyle, resetAll, quit, disableCurrentApp, checkUpdates
}

final class MenuModel: ObservableObject {
    weak var app: TyperApp?
    @Published var snap = MenuSnapshot()

    func refresh() { if let app { snap = app.menuSnapshot() } }

    func bind(_ key: String, _ kp: KeyPath<MenuSnapshot, Bool>) -> Binding<Bool> {
        Binding(get: { self.snap[keyPath: kp] }, set: { self.app?.setToggle(key: key, on: $0); self.refresh() })
    }
    func toggleApp() { app?.setToggle(key: "enabled", on: !snap.enabled); refresh() }
    func toggleCurrentApp() { app?.performMenuAction(.disableCurrentApp); refresh() }
    func action(_ a: MenuAction) { app?.performMenuAction(a); refresh() }
    func setModel(_ variant: String) { app?.setModelVariant(variant); refresh() }
}

// MARK: - Root

struct MenuRootView: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var downloader = ModelDownloader.shared
    private var s: MenuSnapshot { model.snap }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            modelSection
            divider
            stats
            divider
            SwitchRow(title: "Completions", isOn: model.bind("completion_enabled", \.completionEnabled))
            SwitchRow(title: "Typo correction", isOn: model.bind("typo_correction_enabled", \.typoEnabled))
            divider
            sections
            divider
            footer
        }
        .frame(width: kWidth)
        .padding(.vertical, 8)
        // No .fixedSize here: combined with the host's sizingOptions = [.preferredContentSize]
        // it forms an infinite layout-invalidation loop (fitting-size query re-pins the ideal
        // size, which invalidates layout, which re-queries…) that beachballs the app the moment
        // the popover opens. preferredContentSize already sizes the panel from the fixed width
        // and the VStack's ideal height, and resizes it as the collapsible sections expand.
    }

    private var divider: some View { Divider().opacity(0.4).padding(.horizontal, 12).padding(.vertical, 6) }

    private func caption(_ left: String, _ right: String) -> some View {
        HStack {
            Text(left).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(right).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }.padding(.horizontal, kInset)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(s.enabled ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: (s.enabled ? Color.green : Color.red).opacity(0.7), radius: 2.5)
            Text("Typer").font(.system(size: 14, weight: .semibold))
            Text(s.enabled ? "on" : "paused").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Toggle("", isOn: Binding(get: { s.enabled }, set: { _ in model.toggleApp() }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.green)
        }
        .frame(height: 24)
        .padding(.horizontal, kInset).padding(.top, 2)
    }

    // MARK: model size + preference

    // The Small/Large picker, on-demand download progress, and (for Small) the live A/B race bar.
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Model").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                ModelSizePicker(variant: s.modelVariant, downloading: downloader.isDownloading) { model.setModel($0) }
            }.padding(.horizontal, kInset)

            if case let .downloading(frac) = downloader.state {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: frac >= 0 ? frac : nil, total: 1)
                        .progressViewStyle(.linear).tint(.accentColor)
                    Text(frac >= 0 ? "Downloading typer-1l… \(Int(frac * 100))%" : "Downloading typer-1l…")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.horizontal, kInset)
            } else if case let .failed(msg) = downloader.state {
                Text("Download failed — \(msg)").font(.system(size: 10)).foregroundStyle(.red)
                    .padding(.horizontal, kInset)
            } else if s.modelVariant == "large" {
                Text("Large model active · best on 16 GB+ of RAM")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, kInset)
            }

            // Small variant: surface the live raw-vs-distill race when two arms are running.
            if s.modelVariant == "small" {
                if s.racing { modelCard } else if !s.singleModel.isEmpty { caption("Model", s.singleModel) }
            }
        }
    }

    // MARK: model preference

    private var modelCard: some View {
        let aLeads = s.aShare >= 0.5
        let leader = s.lockedName ?? (aLeads ? s.aName : s.bName)
        let label = s.lockedName != nil ? "locked · \(leader)" : "\(leader) leading"
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Model preference").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(label).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(s.lockedName != nil ? Color.green : Color.primary)
            }
            ShareBar(aShare: s.aShare, aLeads: aLeads, locked: s.lockedName != nil)
            HStack {
                Text("\(s.aName) \(pct(s.aShare))").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("\(s.bName) \(pct(1 - s.aShare))").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, kInset)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(s.statsLine1).font(.system(size: 11))
            Text(s.statsLine2).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, kInset)
    }

    // MARK: sections

    private var sections: some View {
        VStack(spacing: 1) {
            MenuSection(title: "Behavior") {
                if s.hasCurrentApp {
                    SwitchRow(title: "Disable in \(s.currentAppName)",
                              isOn: Binding(get: { s.currentAppDisabled }, set: { _ in model.toggleCurrentApp() }))
                }
                SwitchRow(title: "Skip terminal apps", isOn: model.bind("disable_in_terminals", \.disableInTerminals))
                SwitchRow(title: "Battery saver", subtitle: s.batteryThrottling ? "throttling now" : nil,
                          isOn: model.bind("battery_saver", \.batterySaver))
            }
            MenuSection(title: "Context & learning") {
                SwitchRow(title: "Window text", isOn: model.bind("window_context_enabled", \.windowContext))
                SwitchRow(title: "Clipboard", isOn: model.bind("clipboard_context_enabled", \.clipboardContext))
                SwitchRow(title: "Screen OCR", subtitle: "noisy", isOn: model.bind("screen_context_enabled", \.screenContext))
                SwitchRow(title: "Screenshot caret", subtitle: "terminals; battery-heavy", isOn: model.bind("screenshot_caret_enabled", \.screenshotCaret))
                SwitchRow(title: "Remember what I read", subtitle: s.topicCount > 0 ? "\(s.topicCount) topics" : nil, isOn: model.bind("topic_memory_enabled", \.topicMemory))
                SwitchRow(title: "Learn my style", isOn: model.bind("style_memory_enabled", \.styleMemory))
                SwitchRow(title: "Learn my vocabulary", isOn: model.bind("lexicon_enabled", \.lexicon))
                SwitchRow(title: "Adapt to my accepts", isOn: model.bind("adaptive_suggestions", \.adaptive))
            }
            MenuSection(title: "Training & data") {
                SwitchRow(title: "Record my typing",
                          subtitle: s.trainingCount > 0 ? "\(s.trainingCount) samples" : "trains a local model",
                          isOn: model.bind("training_log_enabled", \.trainingEnabled))
                if s.trainingEnabled, s.trainingCount > 0 {
                    ActionRow(title: "Inspect training data…") { model.action(.inspectTraining) }
                }
                if s.racing { ActionRow(title: "Reset model race") { model.action(.resetRace) } }
                ActionRow(title: "Clear learned style") { model.action(.clearStyle) }
                ActionRow(title: "Reset all data…", tint: .red) { model.action(.resetAll) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "gearshape", help: "Open config") { model.action(.config) }
            IconButton(symbol: "doc.plaintext", help: "Open log") { model.action(.log) }
            if s.canUpdate {
                IconButton(symbol: "arrow.triangle.2.circlepath", help: "Check for updates") { model.action(.checkUpdates) }
            }
            Spacer()
            if !s.version.isEmpty {
                Text(s.version).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .help("Installed build")
            }
            Button(action: { model.action(.quit) }) {
                Text("Quit").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
            }.buttonStyle(.plain)
        }.padding(.horizontal, 12)
    }

    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}

// MARK: - Components

// Two-segment bar at a fixed width (no GeometryReader): leader tinted, loser muted.
private struct ShareBar: View {
    let aShare: Double
    let aLeads: Bool
    let locked: Bool
    var body: some View {
        let aw = max(3, min(kBarWidth - 3, kBarWidth * aShare))
        return HStack(spacing: 2) {
            Capsule().fill(color(aLeads)).frame(width: aw - 1)
            Capsule().fill(color(!aLeads))
        }
        .frame(width: kBarWidth, height: 6)
    }
    private func color(_ leading: Bool) -> Color {
        leading ? (locked ? Color.green : Color.accentColor) : Color.secondary.opacity(0.3)
    }
}

// One settings row: leading label (+ optional subtitle), trailing switch. Uniform inset and
// height so every switch lines up down the panel.
private struct SwitchRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.green)
        }
        .frame(minHeight: 26)
        .padding(.horizontal, kInset).padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct ActionRow: View {
    let title: String
    var tint: Color = .primary
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 26)
                .padding(.horizontal, kInset - 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hover = $0 }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover ? 0.1 : 0)))
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }
    }
}

// Two-segment Small/Large model-size selector. Disabled while a download is in flight.
private struct ModelSizePicker: View {
    let variant: String
    let downloading: Bool
    let onPick: (String) -> Void
    var body: some View {
        HStack(spacing: 0) {
            seg("Small", "small")
            seg("Large", "large")
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        .opacity(downloading ? 0.5 : 1)
    }
    private func seg(_ label: String, _ v: String) -> some View {
        let active = variant == v
        return Button(action: { if !downloading { onPick(v) } }) {
            Text(label).font(.system(size: 11, weight: .medium))
                .frame(width: 46, height: 20)
                .foregroundStyle(active ? Color.white : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloading)
    }
}

// Collapsible section: a tappable header with a chevron, content hidden until expanded so the
// panel opens compact.
private struct MenuSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var open = false
    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.12)) { open.toggle() } }) {
                HStack {
                    Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.4)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                }
                .frame(height: 26)
                .contentShape(Rectangle())
                .padding(.horizontal, kInset)
            }.buttonStyle(.plain)
            if open { VStack(spacing: 1) { content }.padding(.bottom, 2) }
        }
    }
}
