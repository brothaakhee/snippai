import SwiftUI

/// First-run setup: a checklist that detects and guides the two macOS permission
/// gates (Screen Recording + iTerm2 control) so the first capture can't silently fail.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    var shortcutDisplay: String = "⌥⇧4"
    var onDone: () -> Void

    var body: some View {
        Group {
            if model.page == .welcome {
                WelcomeCarousel(shortcutDisplay: shortcutDisplay,
                                onGetStarted: { withAnimation(.easeInOut) { model.advanceToChecklist() } })
            } else {
                checklist
            }
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !model.duplicateCopies.isEmpty { duplicateBanner }
                screenRecordingRow
                sectionLabel("Connect iTerm2")
                iTermRunningRow
                iTermAPIRow
                automationRow
                if model.snapshot.claudeDesktopInstalled {
                    sectionLabel("Claude desktop app (optional)")
                    accessibilityRow
                }
            }
            .padding(20)
            Divider()
            footer
        }
        .snippaiWindowChrome()
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
        // Offer the stale-grant repair only while it's not actually granted — that's
        // when "shows on in Settings but the app is denied" can happen (after a re-sign).
        let showRepair = model.snapshot.screenRecording == .notDetermined
                      || model.snapshot.screenRecording == .denied
        // Once the user has tried Grant and the state visibly didn't move, the repair
        // is the likely cure — promote it from a footnote link to a real button.
        let escalate = showRepair && model.screenRecordingGrantAttempted
        var repair: (() -> Void)?
        if showRepair { repair = model.repairScreenRecording }
        return PermissionRow(
            icon: "rectangle.dashed.badge.record",
            title: "Screen Recording",
            detail: model.needsRelaunch
                ? "Granted — relaunch SnippAI to start capturing."
                : "Lets SnippAI capture the region you select.",
            state: model.snapshot.screenRecording,
            actionTitle: model.needsRelaunch ? "Relaunch" : "Grant…",
            action: { model.needsRelaunch ? model.relaunch() : model.grantScreenRecording() },
            secondaryTitle: showRepair
                ? (escalate ? "Still blocked after granting? Reset & Relaunch"
                            : "Shows as allowed in Settings but still blocked? Reset & relaunch.")
                : nil,
            secondaryAction: repair,
            secondaryProminent: escalate
        )
    }

    private var accessibilityRow: some View {
        PermissionRow(
            icon: "accessibility",
            title: "Control the Claude app",
            detail: "Lets SnippAI type your message into the Claude desktop app.",
            state: model.snapshot.accessibility,
            actionTitle: "Grant…",
            action: model.grantAccessibility
        )
    }

    @ViewBuilder
    private var duplicateBanner: some View {
        // A copy on the mounted installer disk image can only be ejected, not trashed —
        // say so, instead of a "Remove" that silently can't work.
        let allOnDiskImage = model.duplicateCopies.allSatisfy(\.needsEject)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .scaledFont(15).foregroundStyle(.orange).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(allOnDiskImage ? "The SnippAI installer is still open"
                                        : "Multiple copies of SnippAI found")
                        .scaledFont(13, weight: .semibold)
                    Text(allOnDiskImage
                         ? "Eject the downloaded disk image — granting permission to the copy on it won't apply here."
                         : "Keep only the one in Applications — granting permission to a stray copy won't apply here.")
                        .scaledFont(11).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Reveal in Finder", action: model.revealDuplicates)
                    .controlSize(.small)
                Button(action: model.removeDuplicates) {
                    if model.busyAction == "duplicates" { ProgressView().controlSize(.small) }
                    else { Text(allOnDiskImage ? "Eject Disk Image" : "Remove extras") }
                }
                .controlSize(.small)
                .disabled(model.busyAction != nil)
            }
            if let status = model.duplicateStatus {
                StatusLabel(text: status)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: PanelStyle.cardRadius))
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
                Label("All set — press \(shortcutDisplay) anywhere to capture.", systemImage: "checkmark.circle.fill")
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
    /// Optional tertiary "link" shown beneath the row (e.g. a repair affordance).
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    /// Renders the secondary as a real bordered button instead of link text — used
    /// when it has become the likely fix and must not be overlooked.
    var secondaryProminent = false
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 22

    /// What to show as the row's secondary line: the "do X first" reason when the
    /// row is gated, otherwise its normal detail.
    private var effectiveDetail: String { enabled ? detail : (disabledReason ?? detail) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                statusBadge   // kept full-opacity so "done vs not" always reads
                content.opacity(enabled ? 1 : 0.6)
            }
            if let secondaryTitle, let secondaryAction {
                Group {
                    if secondaryProminent {
                        Button(secondaryTitle, action: secondaryAction)
                            .controlSize(.small)
                    } else {
                        Button(action: secondaryAction) {
                            Text(secondaryTitle)
                                .scaledFont(10)
                                .foregroundStyle(Color.accentColor)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, iconWidth + 12)   // align under the title text
            }
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
