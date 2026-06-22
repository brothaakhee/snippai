import SwiftUI
import SnippAIKit

extension AgentState {
    /// The badge tint. Kept in the view layer so the SnippAIKit core stays UI-agnostic.
    var tint: Color {
        switch self {
        case .working: return .secondary
        case .finished: return .green
        case .waitingForInput: return .orange
        case .unknown: return .clear
        }
    }

    /// Whether there's anything worth rendering (no badge for `.unknown`).
    var isVisible: Bool { self != .unknown }
}

/// A compact status badge (glyph + optional label) for an agent session's
/// hook-derived state. Pure enrichment over the mirror — absent when unknown.
struct AgentStateBadge: View {
    let state: AgentState
    var showsLabel: Bool = true
    @ScaledMetric(relativeTo: .caption) private var glyph: CGFloat = 11

    var body: some View {
        if state.isVisible {
            HStack(spacing: 4) {
                // "Working" uses the native indeterminate spinner — unmistakably
                // animated. (A rotating SF Symbol like circle.dotted reads as static
                // because it's rotationally symmetric.) Other states are static glyphs.
                if state == .working {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(glyph / 16)   // shrink the ~16pt spinner to glyph size
                        .frame(width: glyph, height: glyph)
                } else {
                    Image(systemName: state.symbolName)
                        .font(.system(size: glyph, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
                if showsLabel {
                    Text(state.label)
                        .scaledFont(10, weight: .semibold)
                }
            }
            .foregroundStyle(state.tint)
            .padding(.horizontal, showsLabel ? 6 : 3)
            .padding(.vertical, showsLabel ? 2 : 1)
            .background(state.tint.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Agent status: \(state.label)")
        }
    }
}
