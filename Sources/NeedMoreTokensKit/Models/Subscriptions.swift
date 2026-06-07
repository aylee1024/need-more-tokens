import Foundation

/// Best-known monthly subscription price per provider/plan (2026). These are the
/// flat fees the user pays — distinct from the estimated token "value" the engine
/// computes. The app surfaces these and lets the user override them, since codexbar
/// reports a plan name ("Claude Max", "Pro 5x", "Paid") but not always the exact tier.
public enum Subscriptions {
    public static func defaultMonthlyUSD(for provider: Provider, planName: String?) -> Double? {
        let plan = (planName ?? "").lowercased()
        switch provider {
        case .claude:
            // Claude Max: $100 (5×) or $200 (20×). codexbar reports only "Claude Max";
            // default to 20× ($200) for a heavy user — overridable in settings.
            if plan.contains("max") { return 200 }
            if plan.contains("pro") { return 20 }
            return nil
        case .codex:
            // OpenAI: Plus $20, Pro 5× $100, Pro 20× $200 (token-credit billing).
            if plan.contains("20x") { return 200 }
            if plan.contains("5x") || plan.contains("pro") { return 100 }
            if plan.contains("plus") { return 20 }
            return nil
        case .gemini:
            // Google AI Pro $19.99/mo; Ultra $99.99/$249.99. Only price a KNOWN paid
            // plan — a missing/failed read must not show a paid subscription line.
            if plan.contains("ultra") { return 99.99 }
            if plan.contains("paid") || plan.contains("pro") { return 19.99 }
            return nil
        }
    }
}
