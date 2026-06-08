import CoreGraphics
import Foundation

/// macOS has no Dynamic Type, so "make the UI bigger" is implemented by hand: text is
/// drawn at a real point size (which stays crisp) and every layout metric is multiplied
/// by a per-step scale. This is the pure math behind that — kept in the Kit so it is unit
/// tested; the SwiftUI font + environment glue lives in the app's `Theme`.
public enum UISize {
    /// UserDefaults key holding the persisted step.
    public static let defaultsKey = "uiSizeStep"
    /// Comfortable starting size; bigger than the cramped macOS baseline that read "too small".
    public static let defaultStep = 2
    public static let minStep = 0
    public static let maxStep = 6

    /// One multiplier per step (`minStep...maxStep`). Step 2 is the default.
    static let scales: [CGFloat] = [0.90, 1.00, 1.15, 1.32, 1.50, 1.70, 1.90]

    public static func clampedStep(_ step: Int) -> Int {
        min(max(step, minStep), maxStep)
    }

    public static func scale(for step: Int) -> CGFloat {
        scales[clampedStep(step)]
    }

    /// A layout length, scaled and pixel-rounded (never below 1 so hairlines survive).
    public static func metric(_ base: CGFloat, scale: CGFloat) -> CGFloat {
        guard base > 0 else { return 0 }
        return max(1, (base * scale).rounded())
    }

    public static func panelMinSize(for scale: CGFloat) -> CGSize {
        CGSize(width: metric(300, scale: scale), height: metric(220, scale: scale))
    }

    public static func panelDefaultSize(for scale: CGFloat) -> CGSize {
        CGSize(width: metric(360, scale: scale), height: metric(440, scale: scale))
    }
}

/// The macOS text styles this app uses, with their base point sizes (the values the
/// system assigns these roles at the default scale). Scaling multiplies these.
public enum TextRole {
    case largeTitle, headline, subheadline, callout, caption, caption2

    public var basePointSize: CGFloat {
        switch self {
        case .largeTitle: 26
        case .headline: 13
        case .subheadline: 11
        case .callout: 12
        case .caption: 10
        case .caption2: 10
        }
    }
}
