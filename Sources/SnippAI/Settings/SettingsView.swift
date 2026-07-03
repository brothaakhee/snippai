import SwiftUI
import SnippAIKit

/// SnippAI settings — currently the capture shortcut. Mirrors the onboarding
/// window's material/typography so the two feel like one app.
struct SettingsView: View {
    @Bindable var store: ShortcutStore
    @Bindable var hooks: HookController
    @Bindable var license: LicenseStore
    @Bindable var launchAtLogin: LaunchAtLoginStore
    var onDone: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var recorder = ShortcutRecorder()
    @State private var message: Message?
    @State private var licenseKeyInput = ""
    @State private var activating = false
    @State private var licenseMessage: Message?

    private struct Message { var text: String; var isWarning: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                shortcutCard
                if let message {
                    Label(message.text, systemImage: message.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .scaledFont(11)
                        .foregroundStyle(message.isWarning ? Color.orange : .green)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                launchAtLoginCard
                claudeStatusCard
                licenseCard
            }
            .padding(20)
            Divider()
            footer
        }
        .snippaiWindowChrome()
        .onAppear { launchAtLogin.refresh() }
        .onDisappear { recorder.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard")
                .scaledFont(26, weight: .medium)
                .foregroundStyle(PanelStyle.accent)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("SnippAI Settings").scaledFont(17, weight: .semibold)
                Text("Choose the keyboard shortcut that captures a region and opens SnippAI.")
                    .scaledFont(12).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: Shortcut card

    private var shortcutCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .scaledFont(15).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Capture & Send").scaledFont(13, weight: .semibold)
                Text(recorder.isRecording ? "Type a shortcut — ⎋ to cancel."
                                          : "Press this anywhere to capture.")
                    .scaledFont(11).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            recorderField
            if !store.isDefault && !recorder.isRecording {
                Button("Reset") { reset() }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PanelStyle.cardRadius))
        .animation(.easeInOut(duration: 0.15), value: recorder.isRecording)
        .animation(.easeInOut(duration: 0.15), value: store.combo)
    }

    // MARK: Launch at login card

    private var launchAtLoginCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "power")
                    .scaledFont(15).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login").scaledFont(13, weight: .semibold)
                    Text("Start SnippAI automatically so \(store.combo.displayString) always works.")
                        .scaledFont(11).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Launch at login")
            }
            if let status = launchAtLogin.statusMessage {
                Label(status, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(10)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PanelStyle.cardRadius))
        .animation(.easeInOut(duration: 0.15), value: launchAtLogin.isEnabled)
    }

    // MARK: Claude Code status card

    private var claudeStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .scaledFont(15).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Claude Code status").scaledFont(13, weight: .semibold)
                        Text("beta")
                            .scaledFont(9, weight: .bold)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Text("Show a “Done / Needs you” badge by letting Claude Code notify SnippAI.")
                        .scaledFont(11).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { hooks.isEnabled },
                    set: { hooks.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Enable Claude Code status")
            }
            Text("Adds two read-only hooks to ~/.claude/settings.json (a timestamped backup is made first). It never blocks Claude, and turning this off removes them.")
                .scaledFont(10).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = hooks.statusMessage {
                Label(status, systemImage: hooks.statusIsWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .scaledFont(10)
                    .foregroundStyle(hooks.statusIsWarning ? Color.orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PanelStyle.cardRadius))
        .animation(.easeInOut(duration: 0.15), value: hooks.isEnabled)
    }

    // MARK: License card

    private var licenseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: license.isLicensed ? "checkmark.seal.fill" : "sparkles")
                    .scaledFont(15)
                    .foregroundStyle(license.isLicensed ? Color.green : PanelStyle.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(license.isLicensed ? "License" : "SnippAI").scaledFont(13, weight: .semibold)
                    Text(license.statusSummary)
                        .scaledFont(11).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if license.isLicensed {
                    Button("Deactivate") { Task { await license.deactivate() } }
                        .controlSize(.small)
                } else {
                    Button("Buy — $8.99") { openURL(LicenseConfig.checkoutURL) }
                        .controlSize(.small)
                }
            }
            if !license.isLicensed {
                HStack(spacing: 8) {
                    TextField("Enter license key", text: $licenseKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(11, design: .monospaced)
                        .disabled(activating)
                        .onSubmit(activateLicense)
                    Button(action: activateLicense) {
                        if activating { ProgressView().controlSize(.small).frame(width: 56) }
                        else { Text("Activate").frame(minWidth: 56) }
                    }
                    .controlSize(.small)
                    .disabled(activating || licenseKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let licenseMessage {
                Label(licenseMessage.text, systemImage: licenseMessage.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .scaledFont(10)
                    .foregroundStyle(licenseMessage.isWarning ? Color.orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PanelStyle.cardRadius))
        .animation(.easeInOut(duration: 0.15), value: license.isLicensed)
        .animation(.easeInOut(duration: 0.15), value: activating)
    }

    private func activateLicense() {
        let trimmed = licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !activating else { return }
        activating = true
        licenseMessage = nil
        Task {
            let result = await license.activate(key: trimmed)
            activating = false
            switch result {
            case .success:
                licenseMessage = Message(text: "License activated — thank you!", isWarning: false)
                licenseKeyInput = ""
            case .failure(let m):
                licenseMessage = Message(text: m, isWarning: true)
            }
        }
    }

    private var recorderField: some View {
        Button(action: toggleRecording) {
            Text(recorder.isRecording ? "…" : store.combo.displayString)
                .scaledFont(13, weight: .medium, design: .rounded)
                .monospacedDigit()
                .frame(minWidth: 56)
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                        .fill(recorder.isRecording ? PanelStyle.accent.opacity(0.18) : Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                        .strokeBorder(recorder.isRecording ? PanelStyle.accent : .clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .help(recorder.isRecording ? "Listening for a shortcut" : "Click to record a new shortcut")
        .accessibilityLabel("Capture shortcut")
        .accessibilityValue(recorder.isRecording ? "recording" : store.combo.displayString)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("Use ⌘, ⌃, or ⌥ with any key. ⌥⇧4 is the default.")
                .scaledFont(11).foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: onDone).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Actions

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            message = nil
            recorder.start(onCapture: handleCapture, onCancel: {})
        }
    }

    private func handleCapture(_ combo: HotKey.KeyCombo) {
        // Keep listening until the user adds a real modifier.
        guard combo.hasRequiredModifier else {
            message = Message(text: "Use ⌘, ⌃, or ⌥ together with a key.", isWarning: true)
            return
        }
        recorder.stop()
        if combo == store.combo {
            message = Message(text: "Shortcut unchanged — already \(combo.displayString).", isWarning: false)
            return
        }
        guard store.update(to: combo) else {
            message = Message(text: "“\(combo.displayString)” is already used by another app. Pick another.", isWarning: true)
            return
        }
        if let conflict = combo.systemShortcutConflict {
            message = Message(text: "Set to \(combo.displayString), but \(conflict) It may not reach SnippAI.", isWarning: true)
        } else {
            message = Message(text: "Shortcut set to \(combo.displayString).", isWarning: false)
        }
    }

    private func reset() {
        recorder.stop()
        store.resetToDefault()
        message = Message(text: "Reset to the default \(store.combo.displayString).", isWarning: false)
    }
}
