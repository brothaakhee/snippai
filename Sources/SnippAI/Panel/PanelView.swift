import SwiftUI
import SnippAIKit

/// The panel's root view: a screenshot header, then either the session picker
/// or the compose view (live mirror + message input).
struct PanelView: View {
    @Bindable var model: AppModel
    var onClose: () -> Void
    var onAddScreenshot: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(model: model, onClose: onClose, onAddScreenshot: onAddScreenshot)
            Divider().opacity(0.5)
            switch model.phase {
            case .picking:
                SessionPickerView(model: model, onCancel: onClose)
            case .composing:
                ComposeView(model: model)
            }
        }
        // Fill the (resizable) window rather than a fixed size, so dragging the
        // panel wider reveals more of the terminal mirror's width.
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        // A deliberate flat dark surface (matches the site) — not the translucent
        // system material, which washes out light/gray over a dark desktop.
        .background(PanelStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: PanelStyle.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: PanelStyle.panelRadius).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        // Visible drag-to-resize affordance in the bottom-right corner.
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .frame(width: 16, height: 16)
                .padding(7)
                .accessibilityLabel("Resize panel")
        }
        .tint(PanelStyle.accent)              // mint send button / selection / focus
        .environment(\.colorScheme, .dark)    // always dark, regardless of system appearance
        .snippaiDynamicTypeClamp()
    }
}

private struct TitleBar: View {
    @Bindable var model: AppModel
    var onClose: () -> Void
    var onAddScreenshot: () -> Void = {}

    /// Convey live, changing state rather than restating the visible thumbnail.
    private var subtitle: String {
        if model.phase == .composing, let session = model.selectedSession {
            return "→ \(session.folderName)"
        }
        if !model.screenshotURLs.isEmpty { return "Choose a session to send to" }
        return "Press ⌥⇧4 to capture"
    }

    var body: some View {
        HStack(spacing: 10) {
            attachments
            VStack(alignment: .leading, spacing: 1) {
                Text("SnippAI").scaledFont(14, weight: .semibold)
                Text(subtitle)
                    .scaledFont(11).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(-1)   // yield width to the thumbnails before truncating
            Spacer(minLength: 4)
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
        .padding(.vertical, PanelStyle.rowPadV)
    }

    /// The staged screenshots as a removable strip, with a trailing "+" to add more.
    /// Falls back to the camera glyph when nothing is staged.
    @ViewBuilder
    private var attachments: some View {
        if model.screenshotURLs.isEmpty {
            Image(systemName: "camera.viewfinder")
                .scaledFont(20)
                .foregroundStyle(.secondary)
                .frame(width: 60, height: 42)
        } else {
            HStack(spacing: 6) {
                ForEach(model.screenshotURLs, id: \.self) { url in
                    ThumbnailChip(url: url) { model.removeScreenshot(url) }
                }
                if model.canAddScreenshot {
                    AddScreenshotButton(action: onAddScreenshot)
                }
            }
        }
    }
}

/// One screenshot thumbnail with a hover-revealed remove button.
private struct ThumbnailChip: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.primary.opacity(0.08)
                }
            }
            .frame(width: 56, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.15)))

            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(13)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(2)
                .transition(.opacity)
                .accessibilityLabel("Remove screenshot")
            }
        }
        .onHover { isHovering in withAnimation(.easeInOut(duration: 0.1)) { hovering = isHovering } }
        // The hover-only × is invisible to VoiceOver, so expose removal as an
        // accessibility action on the chip itself (reachable from the actions rotor).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Screenshot")
        .accessibilityAction(named: Text("Remove screenshot")) { onRemove() }
    }
}

/// The "+" affordance to capture and append another screenshot.
private struct AddScreenshotButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .scaledFont(14, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .foregroundStyle(.secondary.opacity(0.5)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Add another screenshot (⌥⇧4)")
        .accessibilityLabel("Add another screenshot")
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
            TerminalMirrorView(screen: model.screen, scrollKey: model.mirrorScrollKey)
                .clipShape(RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1))
                .padding(.horizontal, PanelStyle.contentInset)
                .padding(.bottom, PanelStyle.rowPadV)
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
            // The identity slides in from the side we're cycling toward, so a ⌘←/⌘→
            // switch reads as directional motion. A constant-width, clipped container
            // keeps the right-hand controls from reflowing as the name changes.
            ZStack(alignment: .leading) {
                targetIdentity(session: model.selectedSession, state: selectedAgentState)
                    .id(model.selectedSessionID)
                    .transition(identityTransition)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            switchControls
        }
        .padding(.horizontal, PanelStyle.contentInset).padding(.vertical, PanelStyle.rowPadV)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.selectedSessionID)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(targetBarAccessibilityLabel)
    }

    private var selectedAgentState: AgentState {
        model.selectedSessionID.map { model.agentState(for: $0) } ?? .unknown
    }

    private func targetIdentity(session: TerminalSession?, state: AgentState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: session?.looksLikeAgent == true ? "sparkles" : "terminal")
                .foregroundStyle(session?.looksLikeAgent == true ? PanelStyle.accent : .secondary)
                .scaledFont(12)
            VStack(alignment: .leading, spacing: 0) {
                Text(session?.folderName ?? "session")
                    .scaledFont(12, weight: .semibold)
                    .lineLimit(1)
                Text(session?.disambiguator ?? "")
                    .scaledFont(10).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // A live-mirror indicator so the terminal's liveness is legible.
            LiveDot()
            // Hook-derived semantic state (Done / Needs you), when known.
            AgentStateBadge(state: state)
        }
    }

    @ViewBuilder
    private var switchControls: some View {
        HStack(spacing: 8) {
            if let pos = model.targetPosition, pos.total > 1 {
                Text("\(pos.index)/\(pos.total)")
                    .scaledFont(10, weight: .medium).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)
                Text("⌘ ←→")
                    .scaledFont(10, design: .rounded)
                    .foregroundStyle(.tertiary)
                    .help("Switch target: ⌘← or ⌘↑ previous · ⌘→ or ⌘↓ next")
                    .accessibilityHidden(true)
            }
            Button("Change") { model.backToPicker() }
                .scaledFont(11)
                .buttonStyle(.borderless)
                .accessibilityHint("Pick a different session")
        }
        .fixedSize()
    }

    private var identityTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let forward = model.cycleDirection >= 0
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private var targetBarAccessibilityLabel: String {
        var label = "Sending to \(model.selectedSession?.folderName ?? "session"), live"
        if let id = model.selectedSessionID {
            let state = model.agentState(for: id)
            if state.isVisible { label += ", \(state.label)" }
        }
        // VoiceOver parity for the cycling UI: announce position + the shortcut, but
        // only when there's actually more than one target to cycle through.
        if let pos = model.targetPosition, pos.total > 1 {
            label += ", target \(pos.index) of \(pos.total)"
            label += ". Press Command Left or Command Right to switch target"
        }
        return label
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
                                 },
                                 onCycleTarget: { model.cycleTarget(by: $0) })
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
                        .strokeBorder(PanelStyle.accent.opacity(inputFocused ? 0.55 : 0), lineWidth: 1.5)
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
                    .background(canSend ? PanelStyle.accent : Color.primary.opacity(0.12), in: Circle())
                    .foregroundStyle(canSend ? .white : .secondary)
                    .shadow(color: PanelStyle.accent.opacity(canSend ? 0.3 : 0), radius: 4, y: 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: canSend)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return) · Shift+Return for a new line")
                .accessibilityLabel(model.isSending ? "Sending" : "Send message")
            }
            // +6 over the VStack's 6 → ~12pt above the footer, matched by the
            // container's 12pt below, so the hint sits with equal breathing room.
            footer.padding(.top, 6)
        }
        .padding(.horizontal, PanelStyle.contentInset).padding(.top, PanelStyle.rowPadV).padding(.bottom, 12)
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
        !model.isSending && (!model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.screenshotURLs.isEmpty)
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
