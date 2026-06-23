import SwiftUI
import SnippAIKit

/// The post-trial paywall. Shown when an expired user attempts to use the app. While
/// grace deferrals remain it offers "Maybe later" (which lets that one action through);
/// once they're spent, a license is required. Uses the app's dark panel aesthetic so the
/// mint accent reads as vivid/active and it feels like the same product.
struct PaywallView: View {
    @Bindable var store: LicenseStore
    let canDefer: Bool
    /// Called after a successful activation — the in-flight action should proceed.
    var onActivated: () -> Void
    /// Called when the user chooses "Maybe later" — proceed once, spend a deferral.
    var onLater: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var activating = false
    @State private var error: String?
    @State private var succeeded = false

    private var canActivate: Bool {
        !activating && !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Group {
            if succeeded { successView } else { mainContent }
        }
        .frame(width: 440).frame(minHeight: 300)
        .background(PanelStyle.surface)
        .tint(PanelStyle.accent)
        .environment(\.colorScheme, .dark)
        .snippaiDynamicTypeClamp()
        .animation(.easeInOut(duration: 0.2), value: succeeded)
        .animation(.easeInOut(duration: 0.15), value: error)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 16) {
                buyButton
                licenseSection
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(11).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .padding(20)
            Divider().opacity(0.5)
            footer
        }
    }

    /// Shown briefly after a successful activation before the window dismisses and the
    /// in-flight action proceeds — so unlocking is an unmistakable, satisfying moment.
    private var successView: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(PanelStyle.accent.opacity(0.16)).frame(width: 66, height: 66)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(PanelStyle.accent)
            }
            Text("You're all set").scaledFont(19, weight: .semibold)
            Text("SnippAI is unlocked — thank you for the support.")
                .scaledFont(12.5).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .scaledFont(26, weight: .medium)
                .foregroundStyle(PanelStyle.accent)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("Unlock SnippAI").scaledFont(18, weight: .semibold)
                Text("Your 7-day free trial has ended. A one-time purchase keeps screenshots flowing straight into Claude — no subscription.")
                    .scaledFont(12).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .padding(.top, 6)   // breathing room under the traffic lights
    }

    // MARK: Buy (primary CTA)

    private var buyButton: some View {
        Button {
            openURL(LicenseConfig.checkoutURL)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cart.fill")
                Text("Buy SnippAI — $8.99 once").fontWeight(.semibold)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").scaledFont(12, weight: .semibold).opacity(0.85)
            }
            .scaledFont(14)
            .foregroundStyle(PanelStyle.surface)          // dark text on the mint fill
            .padding(.vertical, 13).padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(PanelStyle.accent, in: RoundedRectangle(cornerRadius: PanelStyle.cardRadius))
        }
        .buttonStyle(.plain)
        .help("Open the secure Lemon Squeezy checkout")
    }

    // MARK: License entry (secondary)

    private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Already purchased?")
                .scaledFont(11, weight: .semibold).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Paste your license key", text: $key)
                    .textFieldStyle(.plain)
                    .scaledFont(12, design: .monospaced)
                    .disabled(activating)
                    .onSubmit { if canActivate { activate() } }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                activateButton
            }
        }
    }

    private var activateButton: some View {
        Button(action: activate) {
            Group {
                if activating {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Activate").scaledFont(12, weight: .semibold)
                }
            }
            .frame(width: 78, height: 36)
            .foregroundStyle(canActivate ? PanelStyle.surface : .secondary)
            .background(
                (canActivate ? PanelStyle.accent : Color.white.opacity(0.10)),
                in: RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canActivate)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("One-time purchase · macOS 14+")
                .scaledFont(11).foregroundStyle(.tertiary)
            Spacer()
            if canDefer {
                Button(action: onLater) {
                    Text("Maybe later (\(store.dismissalsRemaining) left)")
                        .scaledFont(12, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Use SnippAI once more before unlocking")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Actions

    private func activate() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !activating else { return }
        activating = true
        error = nil
        Task {
            let result = await store.activate(key: trimmed)
            activating = false
            switch result {
            case .success:
                succeeded = true                       // show the "You're all set" confirmation…
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                onActivated()                          // …then dismiss and continue the action
            case .failure(let message):
                error = message
            }
        }
    }
}
