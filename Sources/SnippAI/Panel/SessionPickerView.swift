import SwiftUI
import SnippAIKit

/// Lists discoverable sessions with rich, disambiguating labels — necessary
/// because multiple sessions routinely share one working directory.
struct SessionPickerView: View {
    @Bindable var model: AppModel
    @FocusState private var listFocused: Bool

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
            }
            .buttonStyle(.borderless)
            .help("Refresh sessions")
            .disabled(model.isLoadingSessions)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.sessions) { session in
                            SessionRow(session: session, isSelected: session.id == model.selectedSessionID) {
                                model.choose(sessionID: session.id)
                            }
                            .id(session.id)
                        }
                    }
                    .padding(12)
                }
                // Keyboard-first: arrows move the highlight, Return opens it.
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onAppear { listFocused = true }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); scroll(proxy); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); scroll(proxy); return .handled }
                .onKeyPress(.return) { model.confirmSelection(); return .handled }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        if let id = model.selectedSessionID {
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
        }
    }
}

private struct SessionRow: View {
    let session: TerminalSession
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: session.looksLikeAgent ? "sparkles" : "terminal")
                    .foregroundStyle(session.looksLikeAgent ? Color.accentColor : .secondary)
                    .font(.system(size: 14))
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.folderName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        if session.looksLikeAgent {
                            Text(session.jobName)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(session.disambiguator)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if !session.lastLine.isEmpty {
                        Text(session.lastLine)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color.accentColor.opacity(0.16)
                          : (hovering ? Color.primary.opacity(0.06) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ConnectionErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28)).foregroundStyle(.orange)
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
