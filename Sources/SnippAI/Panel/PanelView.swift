import SwiftUI
import SnippAIKit

/// The panel's root view: a screenshot header, then either the session picker
/// or the compose view (live mirror + message input).
struct PanelView: View {
    @Bindable var model: AppModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(model: model, onClose: onClose)
            Divider().opacity(0.5)
            switch model.phase {
            case .picking:
                SessionPickerView(model: model)
            case .composing:
                ComposeView(model: model)
            }
        }
        .frame(width: 420, height: 560)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

private struct TitleBar: View {
    @Bindable var model: AppModel
    var onClose: () -> Void

    /// Convey live, changing state rather than restating the visible thumbnail.
    private var subtitle: String {
        if model.phase == .composing, let session = model.selectedSession {
            return "→ \(session.folderName)"
        }
        if model.screenshotURL != nil { return "Choose a session to send to" }
        return "Press ⌥⌘4 to capture"
    }

    var body: some View {
        HStack(spacing: 10) {
            if let url = model.screenshotURL, let thumb = NSImage(contentsOf: url) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.12)))
            } else {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("SnippAI").font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ComposeView: View {
    @Bindable var model: AppModel
    @State private var inputFocused = false

    var body: some View {
        VStack(spacing: 0) {
            targetBar
            Divider().opacity(0.4)
            TerminalMirrorView(screen: model.screen)
                .frame(maxHeight: .infinity)
            Divider().opacity(0.4)
            inputBar
        }
        // Escape backs out to the session picker rather than dismissing everything.
        .onExitCommand { model.backToPicker() }
    }

    private var targetBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.selectedSession?.looksLikeAgent == true ? "sparkles" : "terminal")
                .foregroundStyle(.secondary).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 0) {
                Text(model.selectedSession?.folderName ?? "session")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.selectedSession?.disambiguator ?? "")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Change") { model.backToPicker() }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if let error = model.connectionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if model.messageText.isEmpty {
                        Text("Tell Claude what to do…")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 13))
                            .padding(.horizontal, 6).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    MessageInput(text: $model.messageText, onSubmit: send,
                                 onCancel: { model.backToPicker() },
                                 onFocusChange: { focused in
                                     withAnimation(.easeInOut(duration: 0.15)) { inputFocused = focused }
                                 })
                        .frame(minHeight: 36, maxHeight: 96)
                        .fixedSize(horizontal: false, vertical: true)
                        // Only treat genuine user typing (non-empty) as dismissing
                        // the badge — not the programmatic clear that send() performs.
                        .onChange(of: model.messageText) {
                            if !model.messageText.isEmpty { model.clearSentBadge() }
                        }
                }
                .padding(4)
                .background(Color.primary.opacity(inputFocused ? 0.09 : 0.06),
                            in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.accentColor.opacity(inputFocused ? 0.55 : 0), lineWidth: 1.5)
                )

                Button(action: send) {
                    Group {
                        if model.isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                    .frame(width: 32, height: 32)
                    .background(canSend ? Color.accentColor : Color.primary.opacity(0.12), in: Circle())
                    .foregroundStyle(canSend ? .white : .secondary)
                    .animation(.easeInOut(duration: 0.15), value: canSend)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return) · Shift+Return for a new line")
            }
            footer
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private var footer: some View {
        if model.justSent {
            Label(model.statusMessage ?? "Sent — watch Claude work above", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        } else {
            Text("Return to send · Shift+Return for a new line")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canSend: Bool {
        !model.isSending && (!model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.screenshotURL != nil)
    }

    private func send() {
        guard canSend else { return }
        Task { await model.send() }
    }
}
