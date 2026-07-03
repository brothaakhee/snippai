import SwiftUI

/// First-run "How it works" intro — a 3-page carousel (Capture → Compose → Send)
/// shown before the permission checklist so new users understand the flow, where the
/// app lives, and the handful of things that aren't discoverable on their own
/// (custom shortcut, terminal targets, panel dimming). Reachable later from the
/// menu bar's "How it works…" item.
struct WelcomeCarousel: View {
    /// Advance to the permission checklist (also used by "Skip").
    var onGetStarted: () -> Void

    private let pages: [Page]

    // Debug builds: jump straight to a page for inspection/screenshots (SNIPPAI_WELCOME_PAGE).
    @State private var index = {
        #if DEBUG
        Int(ProcessInfo.processInfo.environment["SNIPPAI_WELCOME_PAGE"] ?? "") ?? 0
        #else
        0
        #endif
    }()

    init(shortcutDisplay: String = "⌥⇧4", onGetStarted: @escaping () -> Void) {
        self.onGetStarted = onGetStarted
        self.pages = [
            Page(icon: "camera.viewfinder",
                 title: "Capture anything",
                 body: "Press \(shortcutDisplay) anywhere, then drag to select any region of your screen.",
                 tip: "Prefer a different key? Change the shortcut anytime in Settings."),
            Page(icon: "square.and.pencil",
                 title: "Add your context",
                 body: "The panel opens with your screenshot. Add a note or more shots, then choose where to send it — iTerm2, Terminal, or the Claude desktop app.",
                 tip: "Use the dim control (◐) in the panel to fade it so you can see your work behind it."),
            Page(icon: "paperplane.fill",
                 title: "Send it to your session",
                 body: "Hit Send and your message and screenshots drop straight into your live terminal session.",
                 tip: "SnippAI lives in your menu bar — no Dock icon. Click it anytime to capture, open the panel, or reach Settings."),
        ]
    }

    private struct Page {
        let icon: String
        let title: String
        let body: String
        let tip: String
    }

    /// The current page, always clamped to a valid index. SwiftUI can evaluate `body`
    /// with transient/stale state during animated transitions, and a debug override or
    /// future navigation bug could push `index` out of range — clamping here guarantees
    /// the subscript can never trap (a UI must not crash).
    private var current: Int { min(max(index, 0), pages.count - 1) }
    private var isLast: Bool { current == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            page(pages[current])
                .id(current)                // re-key so the per-page transition fires
                .transition(.opacity)       // animated by the withAnimation at each mutation site
            dots
            Divider()
            footer
        }
        .snippaiWindowChrome()
    }

    // MARK: Page

    private func page(_ p: Page) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(PanelStyle.accent.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: p.icon)
                    .scaledFont(38, weight: .medium)
                    .foregroundStyle(PanelStyle.accent)
            }
            VStack(spacing: 10) {
                Text(p.title).scaledFont(20, weight: .semibold)
                Text(p.body)
                    .scaledFont(13)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(p.tip, systemImage: "lightbulb")
                .scaledFont(11)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PanelStyle.cardRadius))
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)
    }

    // MARK: Dots

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(pages.indices, id: \.self) { i in
                Circle()
                    .fill(i == current ? PanelStyle.accent : Color.primary.opacity(0.18))
                    .frame(width: 7, height: 7)
                    .onTapGesture { withAnimation { index = i } }
                    .accessibilityLabel("Page \(i + 1) of \(pages.count)")
            }
        }
        .padding(.bottom, 14)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if current > 0 {
                Button("Back") { withAnimation { index = max(current - 1, 0) } }
                    .buttonStyle(CarouselButtonStyle(.secondary))
            } else {
                Button("Skip", action: onGetStarted)
                    .controlSize(.small)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(isLast ? "Get started" : "Next") {
                if isLast { onGetStarted() } else { withAnimation { index = min(current + 1, pages.count - 1) } }
            }
            .buttonStyle(CarouselButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)   // Return = Next / Get started
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Buttons for the carousel footer, matching the app's CTA language: a mint `accent`
/// fill with dark text for the primary action, a subtle neutral fill for the
/// secondary. Both share the same height so they align across the footer row.
private struct CarouselButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(13, weight: kind == .primary ? .semibold : .medium)
            .foregroundStyle(kind == .primary ? PanelStyle.surface : Color.primary)
            .padding(.vertical, 7)
            .padding(.horizontal, 16)
            .background(
                kind == .primary
                    ? PanelStyle.accent
                    : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.08),
                in: RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
            .contentShape(RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
