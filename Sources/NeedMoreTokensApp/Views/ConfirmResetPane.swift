import SwiftUI
import NeedMoreTokensKit

struct ConfirmResetPane: View {
    let model: AppModel
    let provider: Provider
    let onDone: () -> Void
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(14)) {
            VStack(alignment: .leading, spacing: scaled(8)) {
                Text("Use a banked reset?")
                    .font(Theme.font(.headline, scale: uiScale, weight: .semibold))

                Text(bodyText)
                    .font(Theme.font(.callout, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: scaled(10)) {
                Button("Cancel") { onDone() }
                    .buttonStyle(.borderless)
                    .font(Theme.font(.callout, scale: uiScale))

                Spacer(minLength: scaled(8))

                Button(openButtonTitle) {
                    model.openResetUI(for: provider)
                    onDone()
                }
                .buttonStyle(.glass)
                .font(Theme.font(.callout, scale: uiScale, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(scaled(14))
    }

    private var openButtonTitle: String {
        switch provider {
        case .codex: "Open Codex"
        case .grok: "Open Grok"
        default: "Open"
        }
    }

    private var bodyText: String {
        switch provider {
        case .grok:
            let count = model.grokResetCount ?? 0
            return "You have \(CodexReset.bannerText(count: count)). Redeeming one clears the current weekly SuperGrok pool. Resets don't stack and they expire. This opens Grok's Usage page, where you can redeem one."
        default:
            let count = model.codexResetCount ?? 0
            return "You have \(CodexReset.bannerText(count: count)). Resets are scarce: one free, more only via referral. This opens Codex, where you can use one to clear your current rate-limit window."
        }
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        UISize.metric(base, scale: uiScale)
    }
}
