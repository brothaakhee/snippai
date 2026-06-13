import SwiftUI

/// First-run setup: a checklist that detects and guides the two macOS permission
/// gates (Screen Recording + iTerm2 control) so the first capture can't silently fail.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                screenRecordingRow
                sectionLabel("Connect iTerm2")
                iTermRunningRow
                iTermAPIRow
                automationRow
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 460)
        .background(.regularMaterial)
        .snippaiDynamicTypeClamp()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .scaledFont(26, weight: .medium)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up SnippAI").scaledFont(17, weight: .semibold)
                Text("Grant screen capture and connect iTerm2 — about a minute.")
                    .scaledFont(12).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: Rows

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(11, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 6).padding(.leading, 2)
    }

    private var screenRecordingRow: some View {
        PermissionRow(
            icon: "rectangle.dashed.badge.record",
            title: "Screen Recording",
            detail: model.needsRelaunch
                ? "Granted — relaunch SnippAI to start capturing."
                : "Lets SnippAI capture the region you select.",
            state: model.snapshot.screenRecording,
            actionTitle: model.needsRelaunch ? "Relaunch" : "Grant…",
            action: { model.needsRelaunch ? model.relaunch() : model.grantScreenRecording() }
        )
    }

    private var iTermRunningRow: some View {
        PermissionRow(
            icon: "terminal",
            title: "iTerm2 running",
            detail: "SnippAI sends your message into a live iTerm2 session.",
            state: model.snapshot.iTermRunning ? .granted : .notDetermined,
            actionTitle: "Launch iTerm2",
            action: model.launchITerm,
            busy: model.busyAction == "iterm"
        )
    }

    private var iTermAPIRow: some View {
        PermissionRow(
            icon: "switch.2",
            title: "iTerm2 Python API",
            detail: "Turn on iTerm2 → Settings → General → Magic → “Enable Python API”.",
            disabledReason: "Launch iTerm2 first.",
            state: model.snapshot.iTermAPIEnabled ? .granted : .notDetermined,
            actionTitle: "Open iTerm2",
            action: model.openITermSettings,
            enabled: model.snapshot.iTermRunning
        )
    }

    private var automationRow: some View {
        let needsSettings = model.snapshot.iTermAutomation == .denied || model.automationError != nil
        return PermissionRow(
            icon: "lock.shield",
            title: "Control iTerm2",
            detail: model.automationError ?? "Allow SnippAI to connect to iTerm2’s API.",
            detailIsError: model.automationError != nil,
            disabledReason: model.snapshot.iTermRunning ? "Enable the Python API first." : "Launch iTerm2 first.",
            state: model.snapshot.iTermAutomation,
            actionTitle: needsSettings ? "Open Settings" : "Grant Access",
            action: { needsSettings ? model.openAutomationSettings() : model.grantAutomation() },
            busy: model.busyAction == "automation",
            enabled: model.snapshot.iTermRunning && model.snapshot.iTermAPIEnabled
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.snapshot.allReady {
                Label("All set — press ⌥⌘4 anywhere to capture.", systemImage: "checkmark.circle.fill")
                    .scaledFont(12).foregroundStyle(.green)
            } else {
                Button("Re-check", action: model.refresh)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)   // Return re-checks, never dismisses mid-setup
                Text("Updates as you grant each item.")
                    .scaledFont(11).foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.snapshot.allReady ? "Done" : "Close", action: onDone)
                .keyboardShortcut(model.snapshot.allReady ? .defaultAction : .cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    var detailIsError = false
    var disabledReason: String?
    let state: PermissionState
    let actionTitle: String
    let action: () -> Void
    var busy = false
    var enabled = true
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 22

    /// What to show as the row's secondary line: the "do X first" reason when the
    /// row is gated, otherwise its normal detail.
    private var effectiveDetail: String { enabled ? detail : (disabledReason ?? detail) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusBadge   // kept full-opacity so "done vs not" always reads
            content.opacity(enabled ? 1 : 0.6)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(stateDescription). \(effectiveDetail)")
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .scaledFont(15)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(13, weight: .semibold)
                Text(effectiveDetail)
                    .scaledFont(11)
                    .foregroundStyle(detailIsError ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if state != .granted {
                Button(action: action) {
                    if busy { ProgressView().controlSize(.small) } else { Text(actionTitle) }
                }
                .controlSize(.small)
                .disabled(!enabled || busy)
            }
        }
    }

    private var statusBadge: some View {
        Group {
            switch state {
            case .granted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .needsRelaunch:
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.orange)
            case .denied:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .blocked:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            case .notDetermined:
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
        }
        .scaledFont(16)
        .accessibilityHidden(true)
    }

    private var stateDescription: String {
        switch state {
        case .granted: return "granted"
        case .needsRelaunch: return "granted, relaunch needed"
        case .denied: return "denied"
        case .blocked(let why): return why
        case .notDetermined: return "not yet granted"
        }
    }
}
