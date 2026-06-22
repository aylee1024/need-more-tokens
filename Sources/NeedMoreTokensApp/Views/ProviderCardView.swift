import SwiftUI
import NeedMoreTokensKit

/// One provider's tile: name + plan, its rate windows (incl. extras like Daily
/// Routines), and a plan/credits line — the flat monthly subscription plus any
/// pay-as-you-go credits, which is what actually maps to money spent.
///
/// Fonts and metrics scale from the app-wide `\.uiScale` (macOS has no Dynamic Type).
struct ProviderCardView: View {
    let entry: WidgetSnapshot.Entry
    let resetCount: Int?
    let onUseReset: (() -> Void)?
    @Environment(\.uiScale) private var uiScale

    init(entry: WidgetSnapshot.Entry, resetCount: Int? = nil, onUseReset: (() -> Void)? = nil) {
        self.entry = entry
        self.resetCount = resetCount
        self.onUseReset = onUseReset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(10)) {
            header

            if entry.windows.isEmpty && entry.extraWindows.isEmpty {
                // Grok has no pollable usage windows by design — its plan line carries the
                // tier + renewal, so the "no windows" notice would be wrong noise. Still show
                // a real error (e.g. expired token) for any provider.
                if entry.state == .error {
                    Text(entry.errorMessage ?? "Couldn't read usage")
                        .font(Theme.font(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                } else if entry.provider != .grok {
                    Text("No usage windows reported")
                        .font(Theme.font(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(entry.windows.enumerated()), id: \.offset) { _, window in
                    UsageBarView(window: window)
                }
                ForEach(Array(entry.extraWindows.enumerated()), id: \.offset) { _, window in
                    UsageBarView(window: window)
                }
            }

            planAndCredits
            resetButton
        }
        .padding(scaled(14))
    }

    private var header: some View {
        HStack(spacing: scaled(8)) {
            Text(entry.provider.displayName)
                .font(Theme.font(.headline, scale: uiScale, weight: .semibold))
            if let plan = entry.planName {
                Text(plan)
                    .font(Theme.font(.caption2, scale: uiScale, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, scaled(6))
                    .padding(.vertical, scaled(2))
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: scaled(4))
            stateDot
        }
    }

    @ViewBuilder private var stateDot: some View {
        switch entry.state {
        case .live:
            Circle().fill(.green).frame(width: scaled(6), height: scaled(6))
        case .stale:
            Circle().fill(.yellow).frame(width: scaled(6), height: scaled(6))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.font(.caption2, scale: uiScale, weight: .semibold))
                .foregroundStyle(.orange)
        case .loading:
            ProgressView().controlSize(Theme.progressSize(for: uiScale))
        case .disabled:
            Circle().fill(.secondary).frame(width: scaled(6), height: scaled(6))
        }
    }

    private var planAndCredits: some View {
        HStack(spacing: scaled(6)) {
            if let price = entry.monthlyPriceUSD {
                Image(systemName: "creditcard")
                    .font(Theme.font(.caption2, scale: uiScale))
                    .foregroundStyle(.tertiary)
                Text("\(formatMoney(price))/mo")
                    .font(Theme.font(.caption, scale: uiScale))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            creditsView
            resetCountView
        }
    }

    @ViewBuilder private var creditsView: some View {
        if let cap = entry.exactMonthlyCap {
            // Claude pay-as-you-go beyond the plan: used of limit.
            Text("Extra \(formatMoney(cap.used)) / \(formatMoney(cap.limit))")
                .font(Theme.font(.caption2, scale: uiScale))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Pay-as-you-go usage beyond your plan (\(cap.periodLabel)).")
        } else if let credits = entry.creditsRemaining {
            Text("\(Int(credits)) credits left")
                .font(Theme.font(.caption2, scale: uiScale))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var resetCountView: some View {
        if CodexReset.isFeatureVisible(provider: entry.provider, resetCount: resetCount),
           let resetCount {
            Text(CodexReset.bannerText(count: resetCount))
                .font(Theme.font(.caption2, scale: uiScale))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var resetButton: some View {
        if CodexReset.isFeatureVisible(provider: entry.provider, resetCount: resetCount),
           let onUseReset {
            Button {
                onUseReset()
            } label: {
                HStack(spacing: scaled(8)) {
                    Text("Use a reset…")
                    Spacer(minLength: scaled(8))
                    Image(systemName: "arrow.up.forward.app")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.glass)
            .font(Theme.font(.callout, scale: uiScale, weight: .medium))
            .disabled(resetCount == 0)
        }
    }

    /// A layout length scaled to the current UI size.
    private func scaled(_ base: CGFloat) -> CGFloat {
        UISize.metric(base, scale: uiScale)
    }
}
