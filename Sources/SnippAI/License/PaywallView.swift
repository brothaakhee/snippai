import SwiftUI
import SnippAIKit

/// The post-trial paywall. Shown when an expired user attempts a capture. While grace
/// deferrals remain it offers "Maybe later" (which lets that one capture through);
/// once they're spent, a license is required. Mirrors the onboarding/settings chrome.
struct PaywallView: View {
    @Bindable var store: LicenseStore
    let canDefer: Bool
    /// Called after a successful activation — the in-flight capture should proceed.
    var onActivated: () -> Void
    /// Called when the user chooses "Maybe later" — proceed once, spend a deferral.
    var onLater: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var activating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                licenseField
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(11).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                buyButton
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 420)
        .background(.regularMaterial)
        .snippaiDynamicTypeClamp()
        .animation(.easeInOut(duration: 0.15), value: error)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .scaledFont(26, weight: .medium)
                .foregroundStyle(PanelStyle.accent)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Unlock SnippAI").scaledFont(17, weight: .semibold)
                Text("Your 7-day free trial has ended. A one-time purchase keeps screenshots flowing straight into Claude — no subscription.")
                    .scaledFont(12).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    // MARK: License entry

    private var licenseField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Have a license key?").scaledFont(12, weight: .semibold).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(12, design: .monospaced)
                    .disabled(activating)
                    .onSubmit(activate)
                Button(action: activate) {
                    if activating {
                        ProgressView().controlSize(.small).frame(width: 60)
                    } else {
                        Text("Activate").frame(minWidth: 60)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(activating || key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: Buy

    private var buyButton: some View {
        Button {
            openURL(LicenseConfig.checkoutURL)
        } label: {
            HStack {
                Image(systemName: "cart.fill")
                Text("Buy SnippAI — $8.99 once").fontWeight(.semibold)
                Spacer()
                Image(systemName: "arrow.up.right")
            }
            .scaledFont(13)
            .padding(.vertical, 11).padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(PanelStyle.accent, in: RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help("Open the secure Lemon Squeezy checkout")
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("One-time purchase · macOS 14+")
                .scaledFont(11).foregroundStyle(.tertiary)
            Spacer()
            if canDefer {
                Button("Maybe later (\(store.dismissalsRemaining) left)", action: onLater)
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
                onActivated()
            case .failure(let message):
                error = message
            }
        }
    }
}
