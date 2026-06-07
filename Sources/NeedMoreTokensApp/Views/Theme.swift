import SwiftUI
import NeedMoreTokensKit

/// Visual vocabulary for the app. Intentionally small; polished further in M5.
enum Theme {
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

/// Compact currency: whole dollars for large amounts, cents for small.
func formatMoney(_ value: Double, code: String = "USD") -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    formatter.maximumFractionDigits = value >= 100 ? 0 : 2
    return formatter.string(from: value as NSNumber) ?? "$\(Int(value))"
}
