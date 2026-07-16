import SwiftUI
import SnippAIKit

/// The Ask side-quest: shows what the user highlighted, takes THEIR question
/// (spoken — the panel listens, same as compose — or typed; empty = "explain
/// this"), and streams the one-shot answer. Esc backs out; the user's main
/// session is never touched.
struct AskView: View {
    @Bindable var ask: AskController
    @Bindable var voice: VoiceController
    let model: AppModel
    var onClose: () -> Void

    @State private var question = ""
    @State private var inputFocused = false
    @ScaledMetric(relativeTo: .body) private var inputMinHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var sendSize: CGFloat = 32

    private var quote: String {
        switch ask.state {
        case .composingQuestion(let q), .answering(let q), .done(let q): return q
        case .inactive: return ""
        }
    }

    private var isComposing: Bool {
        if case .composingQuestion = ask.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // What was highlighted — mono, dimmed, clamped: it's the
                    // subject, not the content.
                    Text(quote)
                        .scaledFont(11, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(PanelStyle.accent.opacity(0.7))
                                .frame(width: 3)
                        }

                    switch ask.state {
                    case .answering where ask.answer.isEmpty:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Asking…").scaledFont(12).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 2)
                    case .answering, .done:
                        Text(ask.answer)
                            .scaledFont(13)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    default:
                        EmptyView()
                    }

                    if let note = ask.statusMessage {
                        StatusLabel(text: note)
                    }
                }
                .padding(PanelStyle.contentInset)
            }
            Divider().opacity(0.4)
            if isComposing {
                questionBar
            } else {
                footer
            }
        }
        // Same voice-first behavior as compose: the question phase listens the
        // moment it appears (gated on real panel visibility — an ordered-out
        // window's hierarchy still fires onAppear).
        .onAppear { startListeningIfComposing() }
        .onChange(of: ask.state) { _, new in
            if case .composingQuestion = new { startListeningIfComposing() }
            else { voice.cancelRecording() }
        }
        .onDisappear {
            voice.cancelRecording()
            ask.cancel()
        }
    }

    // MARK: - Question input (mirrors the compose bar's voice choreography)

    private var questionBar: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if question.isEmpty {
                        if voice.phase == .recording {
                            VoiceWaveform(voice: voice)
                                .padding(.horizontal, 6).padding(.vertical, 8)
                                .allowsHitTesting(false)
                        } else {
                            Text("Ask anything about it — or Return to just explain…")
                                .foregroundStyle(.tertiary)
                                .scaledFont(13)
                                .padding(.horizontal, 6).padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    MessageInput(text: $question, onSubmit: handleSubmit,
                                 onCancel: dismiss,
                                 onFocusChange: { inputFocused = $0 })
                        .frame(minHeight: inputMinHeight, maxHeight: 96)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: question) {
                            // Typing is the deliberate text fallback — stop listening.
                            if !question.isEmpty { voice.cancelRecording() }
                        }
                }
                .padding(4)
                .background(Color.primary.opacity(inputFocused ? 0.09 : 0.06),
                            in: RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                        .strokeBorder(PanelStyle.accent.opacity(inputFocused ? 0.55 : 0), lineWidth: 1.5)
                )

                MicButton(voice: voice, size: sendSize, rowHeight: inputMinHeight + 8,
                          onStopAndReview: stopAndReview)

                Button(action: handleSubmit) {
                    Image(systemName: "arrow.up")
                        .scaledFont(14, weight: .bold)
                        .frame(width: sendSize, height: sendSize)
                        .background(PanelStyle.accent, in: Circle())
                        .foregroundStyle(.white)
                        .frame(height: inputMinHeight + 8)
                }
                .buttonStyle(.plain)
                .help("Ask (Return) — empty question = “explain this”")
                .accessibilityLabel("Ask")
            }
            HStack {
                if voice.phase == .recording {
                    Label("Listening… Return to stop & review — typing switches to text",
                          systemImage: "waveform")
                        .scaledFont(10).foregroundStyle(PanelStyle.accent)
                } else {
                    Text("Return to ask · empty question just explains it")
                        .scaledFont(10).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, PanelStyle.contentInset).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Label("One-off question — your session wasn’t touched", systemImage: "sparkle.magnifyingglass")
                .scaledFont(10).foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .controlSize(.small)
                // Return dismisses. Esc already works via the title bar's close
                // (which owns .cancelAction).
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, PanelStyle.contentInset).padding(.vertical, 10)
    }

    // MARK: - Actions

    private func startListeningIfComposing() {
        // Gate on real panel visibility — the SwiftUI hierarchy stays mounted in an
        // ordered-out window, so onAppear can fire while hidden. A hidden panel
        // must never listen (mirrors ComposeView).
        guard isComposing, model.panelIsVisible else { return }
        Task { await voice.beginRecording() }
    }

    /// Return: recording → stop & drop the transcript in for review; transcribing
    /// → wait; otherwise submit (empty question = the canned explain).
    private func handleSubmit() {
        switch voice.phase {
        case .recording:    stopAndReview()
        case .transcribing: break
        default:
            voice.cancelRecording()
            ask.submit(question: question.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func stopAndReview() {
        Task {
            if let text = await voice.finishAndTranscribe() {
                question = question.isEmpty ? text : question + " " + text
            }
        }
    }

    private func dismiss() {
        voice.cancelRecording()
        ask.cancel()
        onClose()
    }
}
