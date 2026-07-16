import SwiftUI
import SnippAIKit

/// SnippAI settings — currently the capture shortcut. Mirrors the onboarding
/// window's material/typography so the two feel like one app.
struct SettingsView: View {
    @Bindable var store: ShortcutStore
    @Bindable var hooks: HookController
    @Bindable var license: LicenseStore
    @Bindable var launchAtLogin: LaunchAtLoginStore
    @Bindable var voice: VoiceController
    @Bindable var ask: AskController
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
                voiceCard
                askCard
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

    // MARK: Toggle cards (shared scaffold — see SettingsToggleCard below)

    private var launchAtLoginCard: some View {
        SettingsToggleCard(
            icon: "power",
            title: "Launch at login",
            subtitle: "Start SnippAI automatically so \(store.combo.displayString) always works.",
            isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) }),
            toggleLabel: "Launch at login"
        ) {
            if let status = launchAtLogin.statusMessage {
                StatusLabel(text: status)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: launchAtLogin.isEnabled)
    }

    private var voiceCard: some View {
        SettingsToggleCard(
            icon: "mic",
            title: "Voice input",
            beta: true,
            subtitle: "Speak your message — the panel listens when it opens. Return stops to review; typing switches to text.",
            footnote: "Downloads a ~600 MB speech model once. Transcription runs entirely on this Mac — audio never leaves it.",
            isOn: Binding(get: { voice.isEnabled }, set: { voice.setEnabled($0) }),
            toggleLabel: "Enable voice input"
        ) {
            switch voice.phase {
            case .downloading(let fraction):
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))%").scaledFont(10).foregroundStyle(.secondary).monospacedDigit()
                }
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing the model — the first time takes a minute or two.")
                        .scaledFont(10).foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
            if let status = voice.statusMessage {
                StatusLabel(text: status)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: voice.phase)
    }

    private var askCard: some View {
        SettingsToggleCard(
            icon: "sparkle.magnifyingglass",
            title: "Ask",
            beta: true,
            subtitle: "Press ⌥⇧A and select any text on screen — get a quick explanation without touching your session.",
            footnote: AskController.claudeAvailable
                ? "Answers come from a one-off Claude session (haiku, no tools) using your existing Claude Code sign-in."
                : "Needs the Claude Code CLI (`claude`) installed and signed in.",
            isOn: Binding(get: { ask.isEnabled }, set: { ask.setEnabled($0) }),
            toggleLabel: "Enable Ask"
        )
    }

    private var claudeStatusCard: some View {
        SettingsToggleCard(
            icon: "dot.radiowaves.left.and.right",
            title: "Claude Code status",
            beta: true,
            subtitle: "Show a “Done / Needs you” badge by letting Claude Code notify SnippAI.",
            footnote: "Adds two read-only hooks to ~/.claude/settings.json (a timestamped backup is made first). It never blocks Claude, and turning this off removes them.",
            isOn: Binding(get: { hooks.isEnabled }, set: { hooks.setEnabled($0) }),
            toggleLabel: "Enable Claude Code status"
        ) {
            if let status = hooks.statusMessage {
                StatusLabel(text: status, isWarning: hooks.statusIsWarning)
            }
        }
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
                StatusLabel(text: licenseMessage.text, isWarning: licenseMessage.isWarning)
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

/// The house scaffold for a Settings card with a trailing switch: icon column,
/// title (+ optional beta chip), wrapping subtitle, optional tertiary footnote,
/// and a content slot for progress/status rows. Extracted when the fourth
/// hand-rolled copy appeared — every future toggle card inherits the language.
private struct SettingsToggleCard<Content: View>: View {
    let icon: String
    let title: String
    var beta = false
    let subtitle: String
    var footnote: String?
    let isOn: Binding<Bool>
    let toggleLabel: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .scaledFont(15).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).scaledFont(13, weight: .semibold)
                        if beta {
                            Text("beta")
                                .scaledFont(9, weight: .bold)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(subtitle)
                        .scaledFont(11).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(toggleLabel)
            }
            if let footnote {
                Text(footnote)
                    .scaledFont(10).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PanelStyle.cardRadius))
    }
}

extension SettingsToggleCard where Content == EmptyView {
    init(icon: String, title: String, beta: Bool = false, subtitle: String,
         footnote: String? = nil, isOn: Binding<Bool>, toggleLabel: String) {
        self.init(icon: icon, title: title, beta: beta, subtitle: subtitle,
                  footnote: footnote, isOn: isOn, toggleLabel: toggleLabel) { EmptyView() }
    }
}
