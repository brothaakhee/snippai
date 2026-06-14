import SwiftUI

/// SnippAI settings — currently the capture shortcut. Mirrors the onboarding
/// window's material/typography so the two feel like one app.
struct SettingsView: View {
    @Bindable var store: ShortcutStore
    var onDone: () -> Void

    @State private var recorder = ShortcutRecorder()
    @State private var message: Message?

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
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 460)
        .background(.regularMaterial)
        .snippaiDynamicTypeClamp()
        .onDisappear { recorder.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard")
                .scaledFont(26, weight: .medium)
                .foregroundStyle(Color.accentColor)
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

    private var recorderField: some View {
        Button(action: toggleRecording) {
            Text(recorder.isRecording ? "…" : store.combo.displayString)
                .scaledFont(13, weight: .medium, design: .rounded)
                .monospacedDigit()
                .frame(minWidth: 56)
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                        .fill(recorder.isRecording ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                        .strokeBorder(recorder.isRecording ? Color.accentColor : .clear, lineWidth: 1.5)
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
            Text("Use ⌘, ⌃, or ⌥ with any key. ⌥⌘4 is the default.")
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
