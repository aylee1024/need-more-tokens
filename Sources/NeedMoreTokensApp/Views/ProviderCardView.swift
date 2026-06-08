import SwiftUI
import NeedMoreTokensKit

/// One provider's tile: name + plan, its rate windows (incl. extras like Daily
/// Routines), and a plan/credits line — the flat monthly subscription plus any
/// pay-as-you-go credits, which is what actually maps to money spent.
///
/// Fonts and metrics scale from the app-wide `\.uiScale` (macOS has no Dynamic Type).
struct ProviderCardView: View {
    let entry: WidgetSnapshot.Entry
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(10)) {
            header

            if entry.windows.isEmpty && entry.extraWindows.isEmpty {
                Text(entry.state == .error ? (entry.errorMessage ?? "Couldn't read usage") : "No usage windows reported")
                    .font(Theme.font(.caption, scale: uiScale))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(entry.windows.enumerated()), id: \.offset) { _, window in
                    UsageBarView(window: window)
                }
                ForEach(Array(entry.extraWindows.enumerated()), id: \.offset) { _, window in
                    UsageBarView(window: window)
                }
            }

            planAndCredits
        }
        .padding(scaled(14))
    }

    private var header: some View {
        HStack(spacing: scaled(8)) {
            Image(systemName: Theme.symbol(for: entry.provider))
                .font(Theme.font(.headline, scale: uiScale, weight: .semibold))
                .foregroundStyle(Theme.tint(for: entry.provider))
                .frame(width: scaled(18))
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

    /// A layout length scaled to the current UI size.
    private func scaled(_ base: CGFloat) -> CGFloat {
        UISize.metric(base, scale: uiScale)
    }
}
