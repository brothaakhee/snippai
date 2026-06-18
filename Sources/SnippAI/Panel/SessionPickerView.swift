import SwiftUI
import SnippAIKit

/// Lists discoverable sessions with rich, disambiguating labels — necessary
/// because multiple sessions routinely share one working directory.
struct SessionPickerView: View {
    @Bindable var model: AppModel
    var onCancel: () -> Void = {}
    @State private var scrollProxy: ScrollViewProxy?
    @ScaledMetric(relativeTo: .body) private var searchHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Send to")
                .font(.headline)
            Spacer()
            Button {
                Task { await model.refreshSessions() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.medium)
                    .rotationEffect(.degrees(model.isLoadingSessions ? 360 : 0))
                    .animation(model.isLoadingSessions ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: model.isLoadingSessions)
            }
            .buttonStyle(.borderless)
            .help("Refresh sessions")
            .accessibilityLabel("Refresh sessions")
            .disabled(model.isLoadingSessions)
        }
        .padding(.horizontal, PanelStyle.contentInset)
        .padding(.top, 12).padding(.bottom, model.sessions.isEmpty ? 12 : 8)
    }

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 8) {
            SessionSearchField(
                text: $model.pickerQuery,
                focusToken: model.pickerFocusToken,
                onMoveUp: { model.moveSelection(by: -1); scrollToSelection(animated: true) },
                onMoveDown: { model.moveSelection(by: 1); scrollToSelection(animated: true) },
                onSubmit: { model.confirmSelection() },
                onCancelEmpty: onCancel
            )
            .frame(height: searchHeight)
            if !model.pickerQuery.isEmpty {
                Text("\(model.filteredSessions.count) of \(model.sessions.count)")
                    .font(.caption).foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, PanelStyle.contentInset)
        .padding(.bottom, 8)
        .onChange(of: model.pickerQuery) {
            model.ensureSelectionInFilter()
            scrollToSelection(animated: false)   // jump, not jitter, while typing
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.connectionError {
            ConnectionErrorView(message: error) { Task { await model.refreshSessions() } }
        } else if model.isLoadingSessions && model.sessions.isEmpty {
            VStack {
                ProgressView()
                Text("Finding sessions…").font(.callout).foregroundStyle(.secondary).padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.sessions.isEmpty {
            ContentUnavailableView("No iTerm sessions", systemImage: "terminal",
                                   description: Text("Open a session in iTerm2 and refresh."))
        } else {
            VStack(spacing: 0) {
                if model.sessions.count > 1 { searchBar }   // filtering one item is pointless
                resultsList
            }
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        let results = model.filteredSessions
        if results.isEmpty {
            ContentUnavailableView {
                Label("No matching sessions", systemImage: "magnifyingglass")
            } description: {
                Text("No open iTerm2 session matches “\(model.pickerQuery)”.")
            } actions: {
                Button("Clear filter") { model.pickerQuery = "" }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(results) { session in
                            SessionRow(session: session, query: model.pickerQuery,
                                       isSelected: session.id == model.selectedSessionID,
                                       state: model.agentState(for: session.id)) {
                                model.choose(sessionID: session.id)
                            }
                            .id(session.id)
                        }
                    }
                    .padding(PanelStyle.contentInset - 4)
                }
                .onAppear {
                    scrollProxy = proxy
                    if let id = model.selectedSessionID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func scrollToSelection(animated: Bool) {
        guard let id = model.selectedSessionID, let proxy = scrollProxy else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

private struct SessionRow: View {
    let session: TerminalSession
    var query: String = ""
    let isSelected: Bool
    var state: AgentState = .unknown
    let action: () -> Void
    @State private var hovering = false
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 18

    private var tokens: [String] { query.lowercased().split(separator: " ").map(String.init) }

    /// True when the query matched something outside the visible folder name
    /// (e.g. the working-directory path) — we then surface that path so the row
    /// doesn't look like an inexplicable result.
    private var matchedOutsideFolder: Bool {
        guard !tokens.isEmpty else { return false }
        let folder = session.folderName.lowercased()
        return !tokens.allSatisfy { folder.contains($0) }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: session.looksLikeAgent ? "sparkles" : "terminal")
                    .foregroundStyle(session.looksLikeAgent ? PanelStyle.accent : .secondary)
                    .scaledFont(14)
                    .frame(width: iconWidth)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(SessionRow.highlight(session.folderName, tokens: tokens))
                            .scaledFont(13, weight: .semibold)
                            .foregroundStyle(.primary)
                        if session.looksLikeAgent {
                            Text(session.jobName)
                                .scaledFont(10, weight: .medium)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(PanelStyle.accent.opacity(0.18), in: Capsule())
                                .foregroundStyle(PanelStyle.accent)
                        }
                    }
                    Text(session.disambiguator)
                        .scaledFont(11)
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    if matchedOutsideFolder {
                        Text(SessionRow.highlight(abbreviatedPath, tokens: tokens))
                            .scaledFont(11, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    } else if !session.lastLine.isEmpty {
                        Text(session.lastLine)
                            .scaledFont(11, design: .monospaced)
                            .foregroundStyle(.secondary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                AgentStateBadge(state: state, showsLabel: false)
                    .padding(.top, 1)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: PanelStyle.cardRadius)
                    .fill(isSelected ? PanelStyle.accent.opacity(0.16)
                          : (hovering ? Color.primary.opacity(0.06) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PanelStyle.cardRadius)
                    .strokeBorder(isSelected ? PanelStyle.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // One spoken element — agent status, not just color; selection as a trait.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(session.lastLine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var abbreviatedPath: String {
        (session.cwd as NSString).abbreviatingWithTildeInPath
    }

    /// Returns an attributed string with every occurrence of each token accented,
    /// so the user can see exactly what matched (Spotlight/Raycast-style).
    static func highlight(_ text: String, tokens: [String]) -> AttributedString {
        var attr = AttributedString(text)
        guard !tokens.isEmpty else { return attr }
        let lower = Array(text.lowercased())
        var marked = [Bool](repeating: false, count: lower.count)
        for token in tokens where !token.isEmpty {
            let t = Array(token)
            guard t.count <= lower.count else { continue }
            var i = 0
            while i <= lower.count - t.count {
                if Array(lower[i..<i + t.count]) == t {
                    for j in i..<i + t.count { marked[j] = true }
                    i += t.count
                } else { i += 1 }
            }
        }
        for (offset, index) in zip(0..., attr.characters.indices) where offset < marked.count && marked[offset] {
            let next = attr.characters.index(after: index)
            attr[index..<next].foregroundColor = PanelStyle.accent
        }
        return attr
    }

    private var accessibilityLabel: String {
        var parts = [session.folderName]
        if session.looksLikeAgent { parts.append("AI agent, \(session.jobName)") }
        if state.isVisible { parts.append(state.label) }
        parts.append(session.disambiguator)
        return parts.joined(separator: ", ")
    }
}

struct ConnectionErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .scaledFont(28).foregroundStyle(.orange)
            Text("Can't reach iTerm2").font(.headline)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again", action: retry).buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
