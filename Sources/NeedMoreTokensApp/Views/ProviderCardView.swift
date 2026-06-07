import SwiftUI
import NeedMoreTokensKit

/// One provider's tile: name + plan, its rate windows (incl. extras like Daily
/// Routines), and a plan/credits line — the flat monthly subscription plus any
/// pay-as-you-go credits, which is what actually maps to money spent.
struct ProviderCardView: View {
    let entry: WidgetSnapshot.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if entry.windows.isEmpty && entry.extraWindows.isEmpty {
                Text(entry.state == .error ? (entry.errorMessage ?? "Couldn't read usage") : "No usage windows reported")
                    .font(.caption)
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
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: Theme.symbol(for: entry.provider))
                .font(.headline)
                .foregroundStyle(Theme.tint(for: entry.provider))
                .frame(width: 18)
            Text(entry.provider.displayName)
                .font(.headline)
            if let plan = entry.planName {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 4)
            stateDot
        }
    }

    @ViewBuilder private var stateDot: some View {
        switch entry.state {
        case .live:
            Circle().fill(.green).frame(width: 6, height: 6)
        case .stale:
            Circle().fill(.yellow).frame(width: 6, height: 6)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
        case .loading:
            ProgressView().controlSize(.mini)
        case .disabled:
            Circle().fill(.secondary).frame(width: 6, height: 6)
        }
    }

    private var planAndCredits: some View {
        HStack(spacing: 6) {
            if let price = entry.monthlyPriceUSD {
                Image(systemName: "creditcard").font(.caption2).foregroundStyle(.tertiary)
                Text("\(formatMoney(price))/mo")
                    .font(.caption).monospacedDigit()
            }
            Spacer(minLength: 0)
            creditsView
        }
    }

    @ViewBuilder private var creditsView: some View {
        if let cap = entry.exactMonthlyCap {
            // Claude pay-as-you-go beyond the plan: used of limit.
            Text("Extra \(formatMoney(cap.used)) / \(formatMoney(cap.limit))")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Pay-as-you-go usage beyond your plan (\(cap.periodLabel)).")
        } else if let credits = entry.creditsRemaining {
            Text("\(Int(credits)) credits left")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
