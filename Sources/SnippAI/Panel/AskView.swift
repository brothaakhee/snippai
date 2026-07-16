import SwiftUI
import SnippAIKit

/// The Ask side-quest: shows what the user highlighted and streams the one-shot
/// explanation under it. Deliberately spartan — read the answer, Esc, back to work.
struct AskView: View {
    @Bindable var ask: AskController
    var onClose: () -> Void

    private var quote: String {
        switch ask.state {
        case .answering(let q), .done(let q): return q
        case .inactive: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // What was highlighted — mono, dimmed, clamped: it's the
                    // question, not the content.
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

                    if ask.answer.isEmpty, case .answering = ask.state {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Asking…").scaledFont(12).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 2)
                    } else {
                        Text(ask.answer)
                            .scaledFont(13)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let note = ask.statusMessage {
                        StatusLabel(text: note)
                    }
                }
                .padding(PanelStyle.contentInset)
            }
            Divider().opacity(0.4)
            HStack {
                Label("One-off question — your session wasn’t touched", systemImage: "sparkle.magnifyingglass")
                    .scaledFont(10).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .controlSize(.small)
                    // Return dismisses. Esc already works via the title bar's close
                    // (which owns .cancelAction) — claiming it here too would leave
                    // SwiftUI to pick an arbitrary winner between duplicates.
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, PanelStyle.contentInset).padding(.vertical, 10)
        }
        .onDisappear { ask.cancel() }
    }

    private func dismiss() {
        ask.cancel()
        onClose()
    }
}
