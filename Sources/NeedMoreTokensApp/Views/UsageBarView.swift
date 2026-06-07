import SwiftUI
import NeedMoreTokensKit

/// One rate window rendered as a labeled bar. The bar (content, not chrome) uses a
/// solid fill so it reads clearly against the glass panel behind it; the fill width
/// is the used fraction and the color reflects remaining headroom.
struct UsageBarView: View {
    let window: RateWindow
    @ScaledMetric(relativeTo: .caption) private var barHeight: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.remainingColor(window.remainingPercent))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Theme.remainingColor(window.remainingPercent).gradient)
                        .frame(width: window.usedPercent <= 0
                               ? 0
                               : max(3, geometry.size.width * window.usedPercent / 100))
                }
            }
            .frame(height: barHeight)

            if let reset = resetText {
                Text(reset)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The engine sometimes gives a friendly description ("Resets in 14h 51m"); the
    /// direct Claude API gives only a timestamp, which we format relatively.
    private var resetText: String? {
        if let description = window.resetDescription, !description.isEmpty { return description }
        guard let resetsAt = window.resetsAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Resets " + formatter.localizedString(for: resetsAt, relativeTo: Date())
    }
}
