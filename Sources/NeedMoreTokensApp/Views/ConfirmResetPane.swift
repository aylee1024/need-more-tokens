import SwiftUI
import NeedMoreTokensKit

struct ConfirmResetPane: View {
    let model: AppModel
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

                Button("Open Codex") {
                    model.openCodexResetUI()
                    onDone()
                }
                .buttonStyle(.glass)
                .font(Theme.font(.callout, scale: uiScale, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(scaled(14))
    }

    private var bodyText: String {
        let count = model.codexResetCount ?? 0
        return "You have \(CodexReset.bannerText(count: count)). Resets are scarce: one free, more only via referral. This opens Codex, where you can use one to clear your current rate-limit window."
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        UISize.metric(base, scale: uiScale)
    }
}
