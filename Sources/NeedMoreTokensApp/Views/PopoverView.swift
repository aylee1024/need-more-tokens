import SwiftUI
import NeedMoreTokensKit

/// The menu-bar popover. The panel is the Liquid Glass "chrome" layer (the provider
/// tiles get `.glassEffect` inside one `GlassEffectContainer`, per Apple's guidance
/// for multiple glass elements); the bars and text are content that sits on top.
///
/// macOS does not honor Dynamic Type, so the whole popover is scaled explicitly from
/// `uiSizeStep`: a real point-size font per role, and every metric multiplied by `uiScale`.
struct PopoverView: View {
    let model: AppModel
    /// Persistent UI size step (see `UISize`); the A−/A+ controls drive it.
    @AppStorage(UISize.defaultsKey) private var uiSizeStep = UISize.defaultStep
    @State private var showingSettings = false
    @State private var confirmingCodexReset = false
    @State private var signingInToClaude = false

    private var step: Int { UISize.clampedStep(uiSizeStep) }
    private var uiScale: CGFloat { UISize.scale(for: step) }
    private var panelMinSize: CGSize { UISize.panelMinSize(for: uiScale) }
    private var panelIdealSize: CGSize { UISize.panelDefaultSize(for: uiScale) }

    var body: some View {
        VStack(spacing: 0) {
            if signingInToClaude {
                paneHeader("Sign in to Claude") { model.finishClaudeSignIn(); signingInToClaude = false }
                ClaudeSignInPane(model: model, onDone: { signingInToClaude = false })
            } else if confirmingCodexReset {
                confirmHeader
                ConfirmResetPane(model: model, onDone: { confirmingCodexReset = false })
            } else if showingSettings {
                settingsHeader
                SettingsPaneView(model: model, onSignInToClaude: {
                    showingSettings = false
                    startClaudeSignIn()
                })
            } else {
                header
                content
            }
            Divider().opacity(0.25)
            footer
        }
        .frame(minWidth: panelMinSize.width, idealWidth: panelIdealSize.width, maxWidth: .infinity,
               minHeight: panelMinSize.height, maxHeight: .infinity, alignment: .top)
        .environment(\.uiScale, uiScale)
    }

    /// A back-arrow header for a pushed pane, matching the settings/reset panes.
    private func paneHeader(_ title: String, onBack: @escaping () -> Void) -> some View {
        HStack(spacing: scaled(8)) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(Theme.font(.subheadline, scale: uiScale, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Back")
            Text(title)
                .font(Theme.font(.subheadline, scale: uiScale, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, scaled(14))
        .padding(.top, scaled(12))
        .padding(.bottom, scaled(8))
    }

    private var confirmHeader: some View {
        HStack(spacing: scaled(8)) {
            Button { confirmingCodexReset = false } label: {
                Image(systemName: "chevron.left")
                    .font(Theme.font(.subheadline, scale: uiScale, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Back")
            Text("Use a reset")
                .font(Theme.font(.subheadline, scale: uiScale, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, scaled(14))
        .padding(.top, scaled(12))
        .padding(.bottom, scaled(8))
    }

    private var settingsHeader: some View {
        HStack(spacing: scaled(8)) {
            Button { showingSettings = false } label: {
                Image(systemName: "chevron.left")
                    .font(Theme.font(.subheadline, scale: uiScale, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Back")
            Text("Settings")
                .font(Theme.font(.subheadline, scale: uiScale, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, scaled(14))
        .padding(.top, scaled(12))
        .padding(.bottom, scaled(8))
    }

    private var header: some View {
        HStack(spacing: scaled(8)) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(Theme.font(.subheadline, scale: uiScale, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Need More Tokens")
                .font(Theme.font(.subheadline, scale: uiScale, weight: .semibold))
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(Theme.progressSize(for: uiScale))
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.font(.subheadline, scale: uiScale, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(Theme.font(.subheadline, scale: uiScale, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, scaled(14))
        .padding(.top, scaled(12))
        .padding(.bottom, scaled(8))
    }

    @ViewBuilder private var content: some View {
        if model.engineState == .binaryMissing {
            onboarding
        } else if model.entries.isEmpty {
            HStack {
                Spacer()
                if model.engineState == .error, let error = model.lastError {
                    VStack(spacing: scaled(6)) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(Theme.font(.callout, scale: uiScale, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(Theme.font(.callout, scale: uiScale))
                            .foregroundStyle(.secondary)
                    }
                } else if model.engineState == .loading {
                    ProgressView("Reading usage…")
                        .controlSize(Theme.progressSize(for: uiScale))
                        .font(Theme.font(.callout, scale: uiScale))
                } else {
                    // A successful fetch with no entries means every provider is toggled off —
                    // show that, not an endless "Reading usage…" spinner.
                    Text("No providers enabled — turn one on in Settings.")
                        .font(Theme.font(.callout, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(.vertical, scaled(28))
        } else {
            ScrollView {
                GlassEffectContainer(spacing: scaled(10)) {
                    VStack(spacing: scaled(10)) {
                        ForEach(model.entries, id: \.provider) { entry in
                            ProviderCardView(
                                entry: entry,
                                resetCount: entry.provider == .codex ? entry.resetCount : nil,
                                onUseReset: codexResetAction(for: entry),
                                onSignIn: signInAction(for: entry)
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassEffect(in: .rect(cornerRadius: scaled(16)))
                        }
                    }
                }
                .padding(.horizontal, scaled(12))
                .padding(.vertical, scaled(8))
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var onboarding: some View {
        VStack(spacing: scaled(10)) {
            Image(systemName: "bolt.horizontal.circle")
                .font(Theme.font(.largeTitle, scale: uiScale))
                .foregroundStyle(.secondary)
            Text("Usage unavailable")
                .font(Theme.font(.headline, scale: uiScale, weight: .semibold))
            Text("Need More Tokens reads each provider directly. Check credentials, then try again.")
                .font(Theme.font(.caption, scale: uiScale))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Check again") { Task { await model.refresh() } }
                .buttonStyle(.glass)
                .font(Theme.font(.callout, scale: uiScale, weight: .medium))
        }
        .padding(scaled(20))
    }

    private var footer: some View {
        HStack(spacing: scaled(8)) {
            // Error first: otherwise a stale "Updated …" would mask a later failure.
            if let error = model.lastError {
                Text(error)
                    .font(Theme.font(.caption2, scale: uiScale))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let last = model.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                    .font(Theme.font(.caption2, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: scaled(4))
            sizeControl
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(Theme.font(.caption, scale: uiScale))
        }
        .padding(.horizontal, scaled(14))
        .padding(.vertical, scaled(8))
    }

    private var sizeControl: some View {
        HStack(spacing: scaled(1)) {
            Button { uiSizeStep = UISize.clampedStep(step - 1) } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(Theme.font(.callout, scale: uiScale, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(step <= UISize.minStep)
            Button { uiSizeStep = UISize.clampedStep(step + 1) } label: {
                Image(systemName: "textformat.size.larger")
                    .font(Theme.font(.callout, scale: uiScale, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(step >= UISize.maxStep)
        }
        .help("Make the whole UI bigger or smaller")
    }

    /// Only Claude has an in-app sign-in (the others' tokens come from their own CLIs), so a
    /// different provider reporting `requiresSignIn` gets no button rather than a dead one.
    private func signInAction(for entry: WidgetSnapshot.Entry) -> (() -> Void)? {
        guard entry.provider == .claude, entry.requiresSignIn else { return nil }
        return { startClaudeSignIn() }
    }

    private func startClaudeSignIn() {
        signingInToClaude = true
        model.beginClaudeSignIn()
    }

    private func codexResetAction(for entry: WidgetSnapshot.Entry) -> (() -> Void)? {
        guard entry.provider == .codex, model.codexResetMode != .unavailable else { return nil }
        return { confirmingCodexReset = true }
    }

    /// A layout length scaled to the current UI size.
    private func scaled(_ base: CGFloat) -> CGFloat {
        UISize.metric(base, scale: uiScale)
    }
}
