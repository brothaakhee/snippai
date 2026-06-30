import SwiftUI
import SnippAIKit

/// The panel's root view: a screenshot header, then either the session picker
/// or the compose view (live mirror + message input).
struct PanelView: View {
    @Bindable var model: AppModel
    var onClose: () -> Void
    var onAddScreenshot: () -> Void = {}
    /// Called as the user drags the opacity slider, so the controller can fade the
    /// NSPanel (alphaValue) live and persist the value.
    var onOpacityChange: (Double) -> Void = { _ in }
    /// Local mirror of the panel's opacity, seeded from the persisted value so the
    /// slider + readout reflect the true current opacity. Writes flow out via
    /// `onOpacityChange`; the controller is the source of truth for the live alpha.
    @State private var opacity: Double

    init(model: AppModel,
         onClose: @escaping () -> Void,
         onAddScreenshot: @escaping () -> Void = {},
         initialOpacity: Double = 1.0,
         onOpacityChange: @escaping (Double) -> Void = { _ in }) {
        self._model = Bindable(wrappedValue: model)
        self.onClose = onClose
        self.onAddScreenshot = onAddScreenshot
        self.onOpacityChange = onOpacityChange
        self._opacity = State(initialValue: initialOpacity)
    }

    /// Slider binding that updates the live readout AND drives the panel's alpha.
    private var opacityBinding: Binding<Double> {
        Binding(get: { opacity }, set: { opacity = $0; onOpacityChange($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(model: model, opacity: opacityBinding, onClose: onClose, onAddScreenshot: onAddScreenshot)
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
    @Binding var opacity: Double
    var onClose: () -> Void
    var onAddScreenshot: () -> Void = {}
    @State private var showingOpacity = false
    // Scale the circular chrome buttons with Dynamic Type so the glyph never crowds
    // a fixed circle at large text sizes (matches ComposeView's send-button idiom).
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 28

    /// Convey live, changing state rather than restating the visible thumbnail.
    private var subtitle: String {
        if model.phase == .composing, let session = model.selectedSession {
            return "→ \(session.folderName)"
        }
        if !model.screenshotURLs.isEmpty { return "Choose a session to send to" }
        return "Press ⌥⇧4 to capture"
    }

    var body: some View {
        // Top-align so the chrome (title + opacity/close buttons) sits at the top of
        // the row rather than centering against the tall attachment thumbnail — a
        // close button belongs in the top-right corner, not floating mid-height.
        HStack(alignment: .top, spacing: 10) {
            attachments
            VStack(alignment: .leading, spacing: 1) {
                Text("SnippAI").scaledFont(14, weight: .semibold)
                Text(subtitle)
                    .scaledFont(11).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(-1)   // yield width to the thumbnails before truncating
            Spacer(minLength: 4)
            opacityButton
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .scaledFont(11, weight: .bold)
                    .foregroundStyle(.secondary)
                    .frame(width: buttonSize, height: buttonSize)
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

    private var opacityPercent: Int { Int((opacity * 100).rounded()) }
    /// Whether the panel is faded below full opacity — drives the button's active
    /// (mint) tint so the dimmed state reads at a glance.
    private var isDimmed: Bool { opacity < 0.999 }

    /// A compact control (styled like the close button so they read as a pair) that
    /// reveals an opacity slider — lets the user fade the whole panel to see what's
    /// behind it, without crowding the tight title row with an inline slider. It tints
    /// mint while dimmed so the active state is obvious; the exact percentage lives in
    /// the popover (visible live as you drag). The footprint is a FIXED circle that
    /// never grows with the value — a value-dependent width would shift the popover's
    /// anchor mid-drag, sliding the track under the cursor and causing a shake at the
    /// dimmed threshold.
    private var opacityButton: some View {
        Button { showingOpacity.toggle() } label: {
            Image(systemName: "circle.lefthalf.filled")
                .scaledFont(12, weight: .bold)
                .foregroundStyle(isDimmed ? PanelStyle.accent : Color.secondary)
                .frame(width: buttonSize, height: buttonSize)
                .background(isDimmed ? PanelStyle.accent.opacity(0.18) : Color.primary.opacity(0.08),
                            in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Adjust panel opacity")
        .accessibilityLabel("Panel opacity")
        .accessibilityValue("\(opacityPercent) percent")
        .popover(isPresented: $showingOpacity, arrowEdge: .bottom) { opacityPopover }
    }

    private var opacityPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Panel opacity").scaledFont(12, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(opacityPercent)%")
                    .scaledFont(11).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityHidden(true)   // the slider already announces the value
            }
            HStack(spacing: 8) {
                Text("20%").scaledFont(10).foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $opacity, in: 0.2...1.0)
                    .accessibilityLabel("Opacity")
                    .accessibilityValue("\(opacityPercent) percent")
                Text("100%").scaledFont(10).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(PanelStyle.contentInset)
        .frame(width: 240)
        .tint(PanelStyle.accent)
        .environment(\.colorScheme, .dark)
    }

    /// The staged screenshots as a removable strip, with a trailing "+" to add more.
    /// Falls back to the camera glyph when nothing is staged.
    @ViewBuilder
    private var attachments: some View {
        if model.screenshotURLs.isEmpty {
            Image(systemName: "camera.viewfinder")
                .scaledFont(30)
                .foregroundStyle(.secondary)
                .frame(width: 116, height: 82)
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
            .frame(width: 112, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.15)))

            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(16)
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
                .scaledFont(18, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 80)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .foregroundStyle(.secondary.opacity(0.5)))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("Add another screenshot (⌥⇧4)")
        .accessibilityLabel("Add another screenshot")
    }
}

/// The selected session's identity (icon · name · source · status), made into a
/// clickable affordance that brings that terminal/app to the front. Reads as a
/// distinct interactive chip: it tints on hover and reveals an "open" glyph, matching
/// the picker rows' hover treatment.
private struct TargetIdentity: View {
    let session: TerminalSession?
    let state: AgentState
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Image(systemName: session?.looksLikeAgent == true ? "sparkles" : "terminal")
                    .foregroundStyle(session?.looksLikeAgent == true ? PanelStyle.accent : .secondary)
                    .scaledFont(12)
                Text(session?.folderName ?? "session")
                    .scaledFont(13, weight: .semibold)
                    .lineLimit(1)
                // Which app the session lives in, as a colored badge (distinct from the
                // mint shortcut pill).
                if let src = session?.source, !src.isEmpty {
                    SourceBadge(source: src).layoutPriority(1)
                }
                // Hook-derived semantic state (Done / Needs you), when known. Higher
                // layout priority than the name: if the row is tight, the name truncates
                // before the status badge does.
                AgentStateBadge(state: state).layoutPriority(1)
                // Reveal an "open" glyph on hover so the chip reads as clickable.
                Image(systemName: "arrow.up.forward.app")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035))
            )
            .contentShape(RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
        }
        .buttonStyle(.plain)
        .disabled(session == nil)
        .onHover { h in withAnimation(.easeInOut(duration: 0.1)) { hovering = h } }
        .help(helpText)
    }

    private var helpText: String {
        let app = session?.source.isEmpty == false ? session!.source : "the terminal"
        if let loc = session?.locationLabel, !loc.isEmpty {
            return "Bring \(app) to the front — \(loc)"
        }
        return "Bring \(app) to the front"
    }
}

/// The app a session lives in, as a small colored capsule. Terminals share one
/// color; the Claude desktop app gets its own so it stands apart in the picker/header.
private struct SourceBadge: View {
    let source: String

    private var color: Color {
        source == "Claude Desktop"
            ? Color(red: 0.78, green: 0.66, blue: 1.0)   // violet — the desktop app
            : Color(red: 0.49, green: 0.76, blue: 1.0)   // blue — iTerm2 / Terminal.app
    }

    var body: some View {
        Text(source)
            .scaledFont(10, weight: .semibold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .fixedSize()
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
            // Prefer the native-chat transcript mirror (works for terminal AND the
            // desktop app); fall back to the faithful TUI mirror for sessions with no
            // resolvable transcript (e.g. a non-Claude terminal).
            mirror
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

    @ViewBuilder private var mirror: some View {
        // Terminal sessions have a true, cell-accurate screen — always show that
        // faithful TUI mirror. The transcript-driven native chat is only for targets
        // with no terminal screen (the Claude desktop app), or the debug viewer
        // (no selected session). `hasScreenStream != true` covers both.
        if model.conversation.hasVisibleContent, model.selectedSession?.hasScreenStream != true {
            ConversationMirrorView(store: model.conversation, scrollKey: model.mirrorScrollKey)
        } else {
            TerminalMirrorView(screen: model.screen, scrollKey: model.mirrorScrollKey)
        }
    }

    private var targetBar: some View {
        HStack(spacing: 8) {
            // The identity slides in from the side we're cycling toward, so a ⌘←/⌘→
            // switch reads as directional motion. A constant-width, clipped container
            // keeps the right-hand controls from reflowing as the name changes.
            ZStack(alignment: .leading) {
                TargetIdentity(session: model.selectedSession,
                               state: selectedAgentState,
                               onTap: { model.focusSelectedSession() })
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


    @ViewBuilder
    private var switchControls: some View {
        HStack(spacing: 8) {
            if let pos = model.targetPosition, pos.total > 1 {
                HStack(spacing: 6) {
                    Text("\(pos.index)/\(pos.total)")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("⌘ ←→")
                }
                .scaledFont(12, weight: .medium, design: .rounded)
                .foregroundStyle(PanelStyle.accent)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(PanelStyle.accent.opacity(0.14), in: Capsule())
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
                    // Match the input box's single-line height so the circle centers
                    // with the text; with the HStack's .bottom alignment it stays
                    // pinned near the bottom as the box grows multi-line.
                    .frame(height: inputMinHeight + 8)
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
        if model.selectedSession?.supportsInject == false {
            Label("Mirror only — type in the Claude app to reply", systemImage: "eye")
                .scaledFont(10).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.justSent {
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
        !model.isSending
            && model.selectedSession?.supportsInject != false   // mirror-only targets can't receive input
            && (!model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.screenshotURLs.isEmpty)
    }

    private func send() {
        guard canSend else { return }
        Task { await model.send() }
    }
}
