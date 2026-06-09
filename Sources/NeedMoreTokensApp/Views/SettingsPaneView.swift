import SwiftUI
import NeedMoreTokensKit

/// The in-popover settings pane. Today it sets the per-provider monthly subscription
/// price — codexbar reports the plan but not always the exact tier (e.g. Claude Max 5×
/// $100 vs 20× $200), so a manual override settles it. It's the home for later settings
/// too. Scales with the app-wide `\.uiScale` like the rest of the popover.
struct SettingsPaneView: View {
    let model: AppModel
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: scaled(14)) {
                Text("MONTHLY SUBSCRIPTION")
                    .font(Theme.font(.caption2, scale: uiScale, weight: .semibold))
                    .foregroundStyle(.tertiary)

                ForEach(Provider.allCases, id: \.self) { provider in
                    PriceRow(
                        provider: provider,
                        detectedPlan: model.entries.first { $0.provider == provider }?.planName,
                        onChange: { model.applyPriceOverrides() }
                    )
                }

                Text("Each provider shows its detected price. Override it — codexbar reports your plan, not the exact tier, so set Claude to $100 or $200 to match. “Default” reverts.")
                    .font(Theme.font(.caption2, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(scaled(14))
        }
        .frame(maxHeight: .infinity)
    }

    private func scaled(_ base: CGFloat) -> CGFloat { UISize.metric(base, scale: uiScale) }
}

/// One provider's price control, bound to its persisted override. An empty/zero override
/// means "use the detected default", which the field shows so the value is never blank.
private struct PriceRow: View {
    let provider: Provider
    let detectedPlan: String?
    let onChange: () -> Void
    @AppStorage private var override: Double
    @Environment(\.uiScale) private var uiScale

    init(provider: Provider, detectedPlan: String?, onChange: @escaping () -> Void) {
        self.provider = provider
        self.detectedPlan = detectedPlan
        self.onChange = onChange
        _override = AppStorage(wrappedValue: 0, PriceOverrides.key(for: provider))
    }

    private var detectedDefault: Double? {
        Subscriptions.defaultMonthlyUSD(for: provider, planName: detectedPlan)
    }

    /// The effective price the field shows: the override if set, else the detected default.
    private var effective: Double { override > 0 ? override : (detectedDefault ?? 0) }

    private var priceBinding: Binding<Double> {
        Binding(get: { effective }, set: { storePrice($0) })
    }

    /// Persist an edited price. A value equal to the detected default normalizes to 0
    /// ("track the default") so merely focusing/committing the shown default never pins it
    /// as an override; an unchanged commit is dropped so we don't rebuild on a no-op.
    private func storePrice(_ newValue: Double) {
        let next = PriceOverrides.normalize(newValue, default: detectedDefault)
        guard abs(override - next) >= 0.005 else { return }
        override = next
        onChange()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(6)) {
            HStack(spacing: scaled(8)) {
                Text(provider.displayName)
                    .font(Theme.font(.callout, scale: uiScale, weight: .semibold))
                if let plan = detectedPlan {
                    Text(plan)
                        .font(Theme.font(.caption2, scale: uiScale, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: scaled(6)) {
                Text("$")
                    .font(Theme.font(.callout, scale: uiScale))
                    .foregroundStyle(.secondary)
                TextField("", value: priceBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font(.callout, scale: uiScale))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: scaled(72))

                if provider == .claude {
                    presetChip(100)
                    presetChip(200)
                }

                Spacer(minLength: scaled(8))

                Button("Default") { override = 0; onChange() }
                    .buttonStyle(.borderless)
                    .font(Theme.font(.caption, scale: uiScale))
                    .disabled(override <= 0)
            }
        }
    }

    private func presetChip(_ value: Double) -> some View {
        Button("$\(Int(value))") { override = value; onChange() }
            .buttonStyle(.borderless)
            .font(Theme.font(.caption, scale: uiScale, weight: override == value ? .bold : .regular))
            .help("Set \(provider.displayName) to $\(Int(value))/mo")
    }

    private func scaled(_ base: CGFloat) -> CGFloat { UISize.metric(base, scale: uiScale) }
}
