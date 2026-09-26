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
    /// Step 4 is the old default (1.15). Odd steps are the sizes halfway between the old ones.
    public static let defaultStep = 4
    public static let minStep = 0
    public static let maxStep = 12

    /// Written once when a pre-half-step index is doubled. Absent means the stored
    /// step is still on the old 0...6 scale.
    public static let halfStepMigrationKey = "uiSizeHalfSteps"

    /// Even indices are the original whole sizes. Odd indices are halfway between
    /// the neighbors, so each A−/A+ click moves half as far. Step 4 is 1.15.
    static let scales: [CGFloat] = [
        0.90, 0.95,
        1.00, 1.075,
        1.15, 1.235,
        1.32, 1.41,
        1.50, 1.60,
        1.70, 1.80,
        1.90,
    ]

    /// Old steps were 0...6. Doubling the index selects the same multiplier.
    /// A second launch must not double again.
    public static func migrateToHalfSteps(in defaults: UserDefaults) {
        guard defaults.object(forKey: halfStepMigrationKey) == nil else { return }
        let legacyMax = 6
        let legacyDefault = 2
        let stored = defaults.object(forKey: defaultsKey) as? Int ?? legacyDefault
        let legacy = min(max(stored, 0), legacyMax)
        defaults.set(legacy * 2, forKey: defaultsKey)
        defaults.set(true, forKey: halfStepMigrationKey)
    }

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
