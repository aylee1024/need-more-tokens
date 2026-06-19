import SwiftUI
import NeedMoreTokensKit

/// One rate window rendered as a labeled bar. The bar (content, not chrome) uses a
/// solid fill so it reads clearly against the glass panel behind it; the fill width
/// is the used fraction and the color reflects remaining headroom.
///
/// Sizing comes from the app-wide `\.uiScale` (macOS has no Dynamic Type), so the
/// label, percentage, and bar all grow together with the UI-size toggle.
struct UsageBarView: View {
    let window: RateWindow
    @Environment(\.uiScale) private var uiScale

    /// Used %, clamped to 0–100 for the bar geometry so an unclamped view model can't
    /// overdraw the track.
    private var clampedUsed: Double { min(100, max(0, window.usedPercent)) }

    /// The label shows the true value (never negative): an overage above 100% is shown
    /// honestly rather than hidden behind the clamped bar width.
    private var labelPercent: Double { max(0, window.usedPercent) }

    /// "<1%" for a nonzero sub-1% value so the label never reads 0% next to a visible bar.
    private var usedLabel: String {
        if labelPercent > 0 && labelPercent < 1 { return "<1%" }
        if labelPercent > 100 { return ">100%" }
        return "\(Int(labelPercent.rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(5)) {
            HStack(spacing: scaled(6)) {
                Text(window.label)
                    .font(Theme.font(.caption, scale: uiScale, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: scaled(8))
                Text(usedLabel)
                    .font(Theme.font(.caption, scale: uiScale, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.remainingColor(window.remainingPercent))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Theme.remainingColor(window.remainingPercent).gradient)
                        .frame(width: clampedUsed <= 0
                               ? 0
                               : min(geometry.size.width, max(scaled(3), geometry.size.width * clampedUsed / 100)))
                }
            }
            .frame(height: scaled(7))

            if let reset = resetText {
                Text(reset)
                    .font(Theme.font(.caption2, scale: uiScale))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The engine sometimes gives a friendly description ("Resets in 14h 51m"); the
    /// direct API paths give only a timestamp, which we format to hours+minutes
    /// (or days+hours for multi-day windows).
    private var resetText: String? {
        if let description = window.resetDescription, !description.isEmpty { return description }
        guard let resetsAt = window.resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(Date())
        guard seconds > 0 else { return "Resets now" }
        return "Resets in \(Self.formatTimeUntilReset(seconds)) on \(Self.resetTimestampFormatter.string(from: resetsAt))"
    }

    /// Absolute reset time, e.g. "Thursday, June 19, 4:03 AM".
    private nonisolated(unsafe) static let resetTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, h:mm a"
        return formatter
    }()

    /// "6d 21h" for multi-day, "2h 13m" within a day, "13m" within the hour.
    static func formatTimeUntilReset(_ seconds: TimeInterval) -> String {
        // Int(seconds) traps on non-finite/overflowing intervals (a corrupt
        // resetsAt). Guard before converting.
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "a while" }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// A layout length scaled to the current UI size.
    private func scaled(_ base: CGFloat) -> CGFloat {
        UISize.metric(base, scale: uiScale)
    }
}
