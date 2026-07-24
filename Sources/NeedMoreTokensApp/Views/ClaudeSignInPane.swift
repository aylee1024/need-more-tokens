import AppKit
import SwiftUI
import NeedMoreTokensKit

/// The in-app Claude sign-in.
///
/// Anthropic's approval page ends by DISPLAYING a code rather than redirecting back to the
/// app, so something has to carry that code across. Making the user type it would be the
/// worst of both worlds, so this watches the clipboard while it is open: the user clicks
/// Copy on Anthropic's page and the sign-in completes on its own. The text field stays as
/// the fallback for anyone who'd rather paste by hand, and because a silent-only flow would
/// look broken if the clipboard read ever failed.
struct ClaudeSignInPane: View {
    let model: AppModel
    let onDone: () -> Void
    @Environment(\.uiScale) private var uiScale

    @State private var pasted = ""
    /// Pasteboard generation already examined. Seeded below every real changeCount so the FIRST
    /// poll reads what is already on the clipboard — safe now that a candidate must carry this
    /// attempt's verifier, which nothing copied before the attempt existed can.
    @State private var lastChangeCount = -1
    /// The last value we spent on an exchange, so a failure can't loop the watcher on it.
    @State private var lastSubmitted = ""

    private let clipboardTick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(12)) {
            switch model.claudeSignInPhase {
            case .succeeded:
                success
            case .exchanging:
                working
            default:
                instructions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(scaled(16))
        .onReceive(clipboardTick) { _ in pollClipboard() }
    }

    // MARK: - States

    private var instructions: some View {
        VStack(alignment: .leading, spacing: scaled(12)) {
            Text("Approve Claude in your browser")
                .font(Theme.font(.headline, scale: uiScale, weight: .semibold))

            Text("Your browser is open on Anthropic's approval page. Approve, then click the copy button next to the code — this window picks it up automatically.")
                .font(Theme.font(.caption, scale: uiScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: scaled(8)) {
                ProgressView().controlSize(.small)
                Text("Waiting for the code…")
                    .font(Theme.font(.caption, scale: uiScale))
                    .foregroundStyle(.tertiary)
            }

            Divider().opacity(0.25)

            Text("Or paste it here")
                .font(Theme.font(.caption2, scale: uiScale, weight: .semibold))
                .foregroundStyle(.tertiary)

            HStack(spacing: scaled(8)) {
                TextField("code#state", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font(.callout, scale: uiScale))
                    .onSubmit { submit(pasted) }
                Button("Finish") { submit(pasted) }
                    .buttonStyle(.borderedProminent)
                    .font(Theme.font(.callout, scale: uiScale, weight: .medium))
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if case .failed(let message) = model.claudeSignInPhase {
                Text(message)
                    .font(Theme.font(.caption, scale: uiScale))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: scaled(10)) {
                Button("Reopen page") { model.reopenClaudeSignInPage() }
                    .buttonStyle(.borderless)
                    .font(Theme.font(.caption, scale: uiScale))
                Button("Start again") { restart() }
                    .buttonStyle(.borderless)
                    .font(Theme.font(.caption, scale: uiScale))
                Spacer(minLength: 0)
                Button("Cancel") { cancel() }
                    .buttonStyle(.borderless)
                    .font(Theme.font(.caption, scale: uiScale))
            }
        }
    }

    private var working: some View {
        HStack(spacing: scaled(10)) {
            ProgressView().controlSize(.small)
            Text("Signing in…")
                .font(Theme.font(.callout, scale: uiScale))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, scaled(20))
    }

    private var success: some View {
        VStack(alignment: .leading, spacing: scaled(10)) {
            HStack(spacing: scaled(8)) {
                Image(systemName: "checkmark.circle.fill")
                    .font(Theme.font(.headline, scale: uiScale))
                    .foregroundStyle(.green)
                Text("Claude is signed in")
                    .font(Theme.font(.headline, scale: uiScale, weight: .semibold))
            }
            Text("The token is stored and the card is refreshing. NMT keeps it fresh on its own; Anthropic caps how long a sign-in lasts, so you'll do this again in about a month.")
                .font(Theme.font(.caption, scale: uiScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Done") { finish() }
                .buttonStyle(.borderedProminent)
                .font(Theme.font(.callout, scale: uiScale, weight: .medium))
        }
    }

    // MARK: - Behavior

    /// Completes the sign-in the moment a code lands on the clipboard. Strictly filtered: an
    /// unrelated copy must never be spent against the endpoint, and each value is tried once.
    private func pollClipboard() {
        guard model.claudeSignInPhase == .waitingForCode || isFailed else { return }
        guard let expectedState = model.claudeSignInState else { return }
        let board = NSPasteboard.general
        guard board.changeCount != lastChangeCount else { return }
        lastChangeCount = board.changeCount
        guard let copied = board.string(forType: .string),
              ClaudeSignIn.looksLikeCode(copied, expectedState: expectedState) else { return }
        let trimmed = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastSubmitted else { return }
        pasted = trimmed
        submit(trimmed)
    }

    private var isFailed: Bool {
        if case .failed = model.claudeSignInPhase { return true }
        return false
    }

    private func submit(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastSubmitted = trimmed
        Task { await model.submitClaudeSignInCode(trimmed) }
    }

    private func restart() {
        pasted = ""
        lastSubmitted = ""
        lastChangeCount = -1        // re-examine the clipboard against the NEW attempt's state
        model.beginClaudeSignIn()
    }

    private func cancel() {
        model.finishClaudeSignIn()
        onDone()
    }

    private func finish() {
        model.finishClaudeSignIn()
        onDone()
    }

    private func scaled(_ base: CGFloat) -> CGFloat { UISize.metric(base, scale: uiScale) }
}
