import SwiftUI
import SnippAIKit

/// The panel's root view: a screenshot header, then either the session picker
/// or the compose view (live mirror + message input).
struct PanelView: View {
    @Bindable var model: AppModel
    var onClose: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(model: model, onClose: onClose)
            Divider().opacity(0.5)
            switch model.phase {
            case .picking:
                SessionPickerView(model: model, onCancel: onClose)
            case .composing:
                ComposeView(model: model)
            }
        }
        .frame(width: 420, height: 560)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: PanelStyle.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: PanelStyle.panelRadius).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .snippaiDynamicTypeClamp()
    }

    // .regularMaterial reads better than ultraThin over busy desktops; honor
    // Reduce Transparency with a solid surface.
    @ViewBuilder private var background: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Color.clear.background(.regularMaterial)
        }
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
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
                    .accessibilityLabel("Captured screenshot")
            } else {
                Image(systemName: "camera.viewfinder")
                    .scaledFont(18)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("SnippAI").scaledFont(14, weight: .semibold)
                Text(subtitle)
                    .scaledFont(11).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .scaledFont(11, weight: .bold)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close SnippAI")
        }
        .padding(.horizontal, PanelStyle.contentInset)
        .padding(.vertical, 10)
    }
}

private struct ComposeView: View {
    @Bindable var model: AppModel
    @State private var inputFocused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Scale the input box + send button with Dynamic Type so larger text doesn't crowd.
    @ScaledMetric(relativeTo: .body) private var inputMinHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var inputMaxHeight: CGFloat = 96
    @ScaledMetric(relativeTo: .body) private var sendSize: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            targetBar
            // The mirror is an inset, rounded "screen" rather than a full-bleed
            // opaque slab butting against the material — no bracketing dividers.
            TerminalMirrorView(screen: model.screen)
                .clipShape(RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1))
                .padding(.horizontal, PanelStyle.contentInset)
                .padding(.vertical, 8)
                .frame(maxHeight: .infinity)
        }
        // Escape backs out to the session picker rather than dismissing everything.
        .onExitCommand { model.backToPicker() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) { Divider().opacity(0.4); inputBar }
        }
    }

    private var targetBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.selectedSession?.looksLikeAgent == true ? "sparkles" : "terminal")
                .foregroundStyle(model.selectedSession?.looksLikeAgent == true ? Color.accentColor : .secondary)
                .scaledFont(12)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.selectedSession?.folderName ?? "session")
                    .scaledFont(12, weight: .semibold)
                Text(model.selectedSession?.disambiguator ?? "")
                    .scaledFont(10).foregroundStyle(.secondary)
            }
            // A live-mirror indicator so the terminal's liveness is legible.
            LiveDot()
            // Hook-derived semantic state (Done / Needs you), when known. Pure
            // enrichment alongside the live mirror.
            if let id = model.selectedSessionID {
                AgentStateBadge(state: model.agentState(for: id))
            }
            Spacer()
            Button("Change") { model.backToPicker() }
                .scaledFont(11)
                .buttonStyle(.borderless)
                .accessibilityHint("Pick a different session")
        }
        .padding(.horizontal, PanelStyle.contentInset).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sending to \(model.selectedSession?.folderName ?? "session"), live")
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
                            .scaledFont(13)
                            .padding(.horizontal, 6).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    MessageInput(text: $model.messageText, onSubmit: send,
                                 onCancel: { model.backToPicker() },
                                 onFocusChange: { focused in
                                     withAnimation(.easeInOut(duration: 0.15)) { inputFocused = focused }
                                 })
                        .frame(minHeight: inputMinHeight, maxHeight: inputMaxHeight)
                        .fixedSize(horizontal: false, vertical: true)
                        // Only treat genuine user typing (non-empty) as dismissing
                        // the badge — not the programmatic clear that send() performs.
                        .onChange(of: model.messageText) {
                            if !model.messageText.isEmpty { model.clearSentBadge() }
                        }
                }
                .padding(4)
                .background(Color.primary.opacity(inputFocused ? 0.09 : 0.06),
                            in: RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                        .strokeBorder(Color.accentColor.opacity(inputFocused ? 0.55 : 0), lineWidth: 1.5)
                )

                Button(action: send) {
                    Group {
                        if model.isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .scaledFont(14, weight: .bold)
                        }
                    }
                    .frame(width: sendSize, height: sendSize)
                    .background(canSend ? Color.accentColor : Color.primary.opacity(0.12), in: Circle())
                    .foregroundStyle(canSend ? .white : .secondary)
                    .shadow(color: .accentColor.opacity(canSend ? 0.3 : 0), radius: 4, y: 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: canSend)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return) · Shift+Return for a new line")
                .accessibilityLabel(model.isSending ? "Sending" : "Send message")
            }
            footer
        }
        // Extra bottom padding so the footer clears the panel's 14pt rounded corner.
        .padding(.horizontal, PanelStyle.contentInset).padding(.top, 10).padding(.bottom, 16)
    }

    @ViewBuilder
    private var footer: some View {
        if model.justSent {
            Label(model.statusMessage ?? "Sent — watch Claude work above", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
        } else if inputFocused {
            // Training-wheels hint only while composing; the .help tooltip covers the rest.
            Text("Return to send · Shift+Return for a new line")
                .scaledFont(10).foregroundStyle(.secondary)
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

/// A small green "live" dot that gently pulses, signaling the mirror is live.
private struct LiveDot: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1 : (on ? 1 : 0.35))
            .animation(reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}
