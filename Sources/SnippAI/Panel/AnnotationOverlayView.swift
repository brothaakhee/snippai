import SwiftUI
import SnippAIKit

/// The in-place annotation layer: the frozen screen behind, a drag-to-select
/// affordance, and inline PR-style question cards anchored where you pointed.
struct AnnotationOverlayView: View {
    @Bindable var session: AnnotationSession
    @Bindable var voice: VoiceController
    /// True when Screen Recording wasn't granted — no live backdrop/OCR; the
    /// selection path still works.
    var captureUnavailable = false
    /// OCR a region (screen points) → recognized text. Injected by the controller.
    var recognize: (CGRect) async -> String
    var onClose: () -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var busy = false

    private let space = "overlay"
    private let cardWidth: CGFloat = 380

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Frozen screen, dimmed a touch so the annotation layer reads as a mode
            // and the cards pop — but still clearly your real screen.
            Image(decorative: session.backdrop, scale: 1, orientation: .up)
                .resizable()
                .ignoresSafeArea()
            Color.black.opacity(0.28).ignoresSafeArea()

            // Drag-to-select — sits under the cards, so a drag that begins on a card
            // never starts a selection.
            selectionLayer

            if let rect = liveSelection { selectionBox(rect) }

            ForEach(session.annotations) { annotation in
                AnnotationCard(
                    annotation: annotation,
                    voice: voice,
                    isActive: annotation === session.composing,
                    onSubmit: { annotation.submit(question: $0) },
                    onRemove: { remove(annotation) })
                .frame(width: cardWidth)
                .fixedSize(horizontal: false, vertical: true)   // hug content, don't fill the screen
                .offset(cardOffset(for: annotation))
            }

            topHint
        }
        .coordinateSpace(name: space)
        .onExitCommand(perform: onClose)   // Esc
        .onAppear { startListeningIfComposing() }
        .onChange(of: session.annotations.count) { startListeningIfComposing() }
    }

    // MARK: - Selection

    private var selectionLayer: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))   // hit-testable, invisible
            .ignoresSafeArea()
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
                    .onChanged { g in
                        if dragStart == nil { dragStart = g.startLocation }
                        dragCurrent = g.location
                    }
                    .onEnded { g in
                        let rect = CGRect(from: g.startLocation, to: g.location)
                        dragStart = nil; dragCurrent = nil
                        guard rect.width >= 8, rect.height >= 8 else { return }
                        Task { await addAnnotation(for: rect) }
                    })
    }

    private var liveSelection: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return CGRect(from: a, to: b)
    }

    private func selectionBox(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(PanelStyle.accent, lineWidth: 1.5)
            .background(PanelStyle.accent.opacity(0.12))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }

    private func addAnnotation(for rect: CGRect) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let fragment = await recognize(rect)
        guard !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep(); return   // nothing readable in that region
        }
        session.addAnnotation(anchor: rect, fragment: fragment)
        // Recording starts via .onChange(of: annotations.count) — single owner.
    }

    // MARK: - Card placement

    /// Anchor the card just below the selection; flip above when the selection is
    /// low on screen, and clamp horizontally so it never runs off the edge.
    private func cardOffset(for annotation: Annotation) -> CGSize {
        let r = annotation.anchor
        let screenH = session.backdropSize.height
        let x = min(max(8, r.minX), session.backdropSize.width - cardWidth - 8)
        let below = r.maxY + 10
        let y = below > screenH * 0.62 ? max(8, r.minY - 260) : below
        return CGSize(width: x, height: y)
    }

    // MARK: - Voice

    private func startListeningIfComposing() {
        guard session.composing != nil else { return }
        Task { await voice.beginRecording() }
    }

    private func remove(_ annotation: Annotation) {
        if annotation === session.composing { voice.cancelRecording() }
        session.remove(annotation)
    }

    // MARK: - Chrome

    private var topHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(PanelStyle.accent)
            Text(captureUnavailable
                 ? "Select text, then ask — enable Screen Recording to point at anything"
                 : "Drag over anything to ask about it")
                .scaledFont(12, weight: .medium)
            Text("Esc to close").scaledFont(11).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 22)
    }
}

private extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y),
                  width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
