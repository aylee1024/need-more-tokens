import SwiftUI
import NeedMoreTokensKit

/// The menu-bar popover. The panel is the Liquid Glass "chrome" layer (the provider
/// tiles get `.glassEffect` inside one `GlassEffectContainer`, per Apple's guidance
/// for multiple glass elements); the bars and text are content that sits on top.
struct PopoverView: View {
    let model: AppModel
    /// Persistent UI size step (0 = system default; higher = bigger fonts + layout).
    @AppStorage("uiSizeStep") private var uiSizeStep: Int = 1

    private static let maxSizeStep = 6

    private var dynamicSize: DynamicTypeSize {
        switch uiSizeStep {
        case ...0: .large
        case 1: .xLarge
        case 2: .xxLarge
        case 3: .xxxLarge
        case 4: .accessibility1
        case 5: .accessibility2
        default: .accessibility3
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            Divider().opacity(0.25)
            footer
        }
        .frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity,
               minHeight: 220, maxHeight: .infinity, alignment: .top)
        .dynamicTypeSize(dynamicSize)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .foregroundStyle(.tint)
            Text("Need More Tokens")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        if model.engineState == .binaryMissing {
            onboarding
        } else if model.entries.isEmpty {
            HStack {
                Spacer()
                if model.engineState == .error, let error = model.lastError {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Reading usage…").controlSize(.small)
                }
                Spacer()
            }
            .padding(.vertical, 28)
        } else {
            ScrollView {
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        ForEach(model.entries, id: \.provider) { entry in
                            ProviderCardView(entry: entry)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassEffect(in: .rect(cornerRadius: 16))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var onboarding: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Engine not found").font(.headline)
            Text("Need More Tokens runs on the codexbar engine. Install it, then check again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("brew install --cask codexbar")
                .font(.caption.monospaced())
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
            Button("Check again") { Task { await model.refresh() } }
                .buttonStyle(.glass)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let last = model.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let error = model.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
            Spacer()
            sizeControl
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var sizeControl: some View {
        HStack(spacing: 1) {
            Button { uiSizeStep = max(0, uiSizeStep - 1) } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .buttonStyle(.borderless)
            .disabled(uiSizeStep <= 0)
            Button { uiSizeStep = min(Self.maxSizeStep, uiSizeStep + 1) } label: {
                Image(systemName: "textformat.size.larger")
            }
            .buttonStyle(.borderless)
            .disabled(uiSizeStep >= Self.maxSizeStep)
        }
        .help("Make the whole UI bigger or smaller")
    }
}
