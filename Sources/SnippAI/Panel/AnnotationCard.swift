import SwiftUI
import SnippAIKit

/// One anchored question thread on the overlay: the quoted sentence, a voice/text
/// composer while it's the active thread, then the streamed answer.
struct AnnotationCard: View {
    @Bindable var annotation: Annotation
    @Bindable var voice: VoiceController
    let isActive: Bool
    var onSubmit: (String?) -> Void
    var onRemove: () -> Void

    @State private var question = ""
    @State private var inputFocused = false
    @ScaledMetric(relativeTo: .body) private var micSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch annotation.phase {
            case .composing: composer
            case .answering, .done: answerBody
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isActive ? PanelStyle.accent.opacity(0.6) : .white.opacity(0.12),
                              lineWidth: isActive ? 1.5 : 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .environment(\.colorScheme, .dark)
        .tint(PanelStyle.accent)
    }

    // MARK: - Header (the quoted sentence)

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(PanelStyle.accent.opacity(0.7)).frame(width: 3)
            Text(annotation.quote)
                .scaledFont(11, design: .monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark").scaledFont(9, weight: .semibold).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove question")
        }
    }

    // MARK: - Composer (active thread)

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if question.isEmpty {
                        if voice.phase == .recording {
                            VoiceWaveform(voice: voice)
                                .padding(.horizontal, 6).padding(.vertical, 8).allowsHitTesting(false)
                        } else {
                            Text("Ask about this — or Return to explain…")
                                .foregroundStyle(.tertiary).scaledFont(12.5)
                                .padding(.horizontal, 6).padding(.vertical, 8).allowsHitTesting(false)
                        }
                    }
                    MessageInput(text: $question, onSubmit: submit,
                                 onCancel: onRemove,
                                 onFocusChange: { inputFocused = $0 })
                        .frame(minHeight: 34, maxHeight: 84)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: question) { if !question.isEmpty { voice.cancelRecording() } }
                }
                .padding(4)
                .background(Color.primary.opacity(inputFocused ? 0.09 : 0.06),
                            in: RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                    .strokeBorder(PanelStyle.accent.opacity(inputFocused ? 0.55 : 0), lineWidth: 1.5))

                MicButton(voice: voice, size: micSize, rowHeight: 42, onStopAndReview: stopAndReview)
                Button(action: submit) {
                    Image(systemName: "arrow.up").scaledFont(13, weight: .bold)
                        .frame(width: micSize, height: micSize)
                        .background(PanelStyle.accent, in: Circle()).foregroundStyle(.white)
                        .frame(height: 42)
                }
                .buttonStyle(.plain)
                .help("Ask (Return) — empty question = explain this")
            }
            Text(voice.phase == .recording ? "Listening… Return to ask"
                                           : "Return to ask · empty just explains it")
                .scaledFont(9.5).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Answer

    private var answerBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if annotation.answer.isEmpty, annotation.phase == .answering {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking…").scaledFont(12).foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    Text(annotation.answer)
                        .scaledFont(12.5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
            if let status = annotation.status { StatusLabel(text: status) }
        }
    }

    // MARK: - Actions

    /// Return: recording → stop, transcribe, submit in one press; transcribing →
    /// wait; else submit (empty = explain).
    private func submit() {
        switch voice.phase {
        case .recording:
            Task {
                let spoken = await voice.finishAndTranscribe()
                let merged = [question, spoken]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: " ")
                onSubmit(merged.isEmpty ? nil : merged)
            }
        case .transcribing: break
        default:
            voice.cancelRecording()
            onSubmit(question.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func stopAndReview() {
        Task {
            if let text = await voice.finishAndTranscribe() {
                question = question.isEmpty ? text : question + " " + text
            }
        }
    }
}
