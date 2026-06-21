import SwiftUI
import SnippAIKit

/// A native chat rendering of a Claude Code conversation, built from decoded
/// transcript turns rather than scraping the TUI. This is the UI-agnostic mirror:
/// it renders identically whether the session runs in a terminal or the desktop app,
/// because both write the same transcript JSONL.
struct ConversationMirrorView: View {
    let store: ConversationStore

    /// Force a snap to the tail (session switch / fresh send). Live updates follow
    /// the tail only if already near the bottom.
    var scrollKey: String = ""

    private var turns: [TranscriptEvent] {
        // Sub-agent/sidechain turns live in separate files and add noise here; the
        // main thread is what the user is conversing with.
        store.events.filter { !$0.isSidechain }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(turns) { turn in
                        TurnView(turn: turn).id(turn.id)
                    }
                    // Tail anchor for reliable scroll-to-bottom.
                    Color.clear.frame(height: 1).id(Self.tailID)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(PanelStyle.surface)
            .overlay { if turns.isEmpty { emptyState } }
            .onChange(of: store.revision) { _, _ in scrollToTail(proxy) }
            .onChange(of: scrollKey) { _, _ in scrollToTail(proxy, animated: false) }
            .onAppear { scrollToTail(proxy, animated: false) }
        }
    }

    private static let tailID = "conversation-tail"

    private func scrollToTail(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !turns.isEmpty else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(Self.tailID, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.tailID, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Waiting for the conversation…")
                .scaledFont(11).foregroundStyle(.secondary)
        }
    }
}

// MARK: - One turn

private struct TurnView: View {
    let turn: TranscriptEvent

    private var isUser: Bool { turn.role == .user && !turn.isToolResultEnvelope }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                ForEach(Array(turn.blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block, isUser: isUser)
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

// MARK: - One content block

private struct BlockView: View {
    let block: TranscriptBlock
    let isUser: Bool

    var body: some View {
        switch block {
        case .text(let text):
            Text(text)
                .scaledFont(12)
                .foregroundStyle(isUser ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                .multilineTextAlignment(isUser ? .trailing : .leading)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(bubbleBackground)

        case .thinking(let text):
            DisclosureBlock(label: "Thinking", systemImage: "brain", text: text)

        case .toolUse(let name, let input):
            ChipView(systemImage: "wrench.and.screwdriver",
                     title: name,
                     detail: input,
                     tint: PanelStyle.accent)

        case .toolResult(let text, let isError):
            ChipView(systemImage: isError ? "exclamationmark.triangle" : "arrow.turn.down.right",
                     title: isError ? "error" : "result",
                     detail: text,
                     tint: isError ? .orange : .secondary)

        case .image:
            ChipView(systemImage: "photo", title: "image", detail: "", tint: .secondary)

        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder private var bubbleBackground: some View {
        if isUser {
            RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                .fill(PanelStyle.accent.opacity(0.9))
        } else {
            RoundedRectangle(cornerRadius: PanelStyle.controlRadius)
                .fill(.white.opacity(0.05))
        }
    }
}

/// A compact, monospaced chip for tool calls / results — truncated so a big tool
/// output doesn't dominate the mirror.
private struct ChipView: View {
    let systemImage: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage).scaledFont(10).foregroundStyle(tint)
            Text(title).scaledFont(11, weight: .semibold, design: .monospaced).foregroundStyle(tint)
            if !detail.isEmpty {
                Text(oneLine(detail))
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.04)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func oneLine(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ")
        return collapsed.count > 160 ? String(collapsed.prefix(160)) + "…" : collapsed
    }
}

/// Collapsible block for thinking — collapsed by default to keep the chat readable.
private struct DisclosureBlock: View {
    let label: String
    let systemImage: String
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").scaledFont(9)
                    Image(systemName: systemImage).scaledFont(10)
                    Text(label).scaledFont(11, weight: .medium)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .scaledFont(11)
                    .foregroundStyle(.secondary)
                    .italic()
                    .textSelection(.enabled)
                    .padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
