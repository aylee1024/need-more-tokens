import SwiftUI
import NeedMoreTokensKit

/// Visual vocabulary for the app. Intentionally small; polished further in M5.
enum Theme {
    // MARK: - UI scale (pure math is NeedMoreTokensKit.UISize; this is the SwiftUI glue)

    /// A real point-size font for `role`, scaled by `scale`. Renders crisply at any size.
    static func font(_ role: TextRole, scale: CGFloat,
                     weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: (role.basePointSize * scale * 2).rounded() / 2, weight: weight, design: design)
    }

    /// Monospaced variant (for digits / shell commands) that scales the same way.
    static func monospacedFont(_ role: TextRole, scale: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(role, scale: scale, weight: weight, design: .monospaced)
    }

    /// A progress-spinner control size that grows with the UI scale (spinners take no font).
    static func progressSize(for scale: CGFloat) -> ControlSize {
        switch scale {
        case ..<1.2: .small
        case ..<1.6: .regular
        default: .large
        }
    }

    /// Green when there's headroom, amber when getting tight, red when nearly out.
    static func remainingColor(_ remainingPercent: Double) -> Color {
        switch remainingPercent {
        case ..<15: .red
        case ..<40: .orange
        default: .green
        }
    }

    static func symbol(for provider: Provider) -> String {
        switch provider {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .gemini: "diamond.fill"
        }
    }

    static func tint(for provider: Provider) -> Color {
        switch provider {
        case .claude: Color(red: 0.80, green: 0.49, blue: 0.31) // terracotta
        case .codex: Color(white: 0.82)
        case .gemini: Color(red: 0.32, green: 0.55, blue: 0.96) // blue
        }
    }
}

private struct UIScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue = UISize.scale(for: UISize.defaultStep)
}

extension EnvironmentValues {
    /// The app-wide UI magnification. macOS has no Dynamic Type, so views read this
    /// and multiply their own fonts and metrics by it.
    var uiScale: CGFloat {
        get { self[UIScaleEnvironmentKey.self] }
        set { self[UIScaleEnvironmentKey.self] = newValue }
    }
}

/// Compact currency: whole dollars for large amounts, cents for small.
func formatMoney(_ value: Double, code: String = "USD") -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    formatter.maximumFractionDigits = value >= 100 ? 0 : 2
    return formatter.string(from: value as NSNumber) ?? "$\(Int(value))"
}
