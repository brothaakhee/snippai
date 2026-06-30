import AppKit

/// Guards SnippAI against the install-time states that silently break macOS
/// permissions:
///
///  • **App Translocation** — when a quarantined app is launched in place (from
///    the DMG, Downloads, or Desktop), Gatekeeper runs it from a random read-only
///    path. Any TCC grant (Screen Recording / Accessibility) binds to that random
///    path and is gone on the next launch, so permissions can *never* stick. The
///    only cure is to run from a stable location — `/Applications`.
///
///  • **Duplicate copies** — granting permission to one copy while launching another
///    leaves the user staring at a permission that "won't take".
///
/// `relocateIfNeeded()` self-heals the first case; `otherCopies()`/`removeCopies()`
/// surface and clean up the second.
@MainActor
enum InstallGuard {
    /// The canonical `/Applications/<App>.app` destination, derived from the running
    /// bundle's own name so a rename can't silently misplace the relocated copy.
    private static let applicationsURL = URL(fileURLWithPath: "/Applications")
        .appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)

    // MARK: - Relocation

    /// If SnippAI is running from a location that breaks TCC (translocated, on the
    /// DMG, or sitting in Downloads/Desktop), copy it into `/Applications`, launch
    /// that copy, and quit. Returns `true` when relocation was started — the caller
    /// MUST abort the rest of launch, because the process is terminating.
    @discardableResult
    static func relocateIfNeeded() -> Bool {
        // Escape hatch for development and tests (e.g. running build/SnippAI.app).
        if ProcessInfo.processInfo.environment["SNIPPAI_NO_RELOCATE"] == "1" { return false }

        let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard needsRelocation(current.path) else { return false }

        do {
            try relocate(from: current)
            return true
        } catch {
            // Don't strand the user with a dead app — fall back to running in place
            // (degraded: grants may not persist) and tell them to move it manually.
            let alert = NSAlert()
            alert.messageText = "Move SnippAI to Applications"
            alert.informativeText = """
            SnippAI couldn't move itself into your Applications folder, and macOS won't \
            reliably remember Screen Recording permission until it lives there. Please drag \
            SnippAI into Applications, then relaunch it.
            """
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }
    }

    /// The locations where running in place breaks TCC. Anything else — `/Applications`,
    /// `~/Applications`, or a developer build directory — is left untouched.
    private static func needsRelocation(_ path: String) -> Bool {
        if path.contains("/AppTranslocation/") { return true }   // Gatekeeper run-in-place
        if path.hasPrefix("/Volumes/") { return true }           // running straight from the DMG

        let home = NSHomeDirectory()
        for dir in ["Downloads", "Desktop"] {
            if path.hasPrefix("\(home)/\(dir)/") { return true }  // "didn't drag it" spots
        }
        return false
    }

    private static func relocate(from source: URL) throws {
        let fm = FileManager.default

        // Replacing the bundle at the destination requires no other copy to be running
        // from it; quit every *other* SnippAI instance first.
        quitOtherInstances()

        // Move an existing /Applications copy to the Trash (reversible) before copying in.
        if fm.fileExists(atPath: applicationsURL.path) {
            if (try? trash(applicationsURL)) == nil {
                try? fm.removeItem(at: applicationsURL)
            }
        }

        try fm.copyItem(at: source, to: applicationsURL)

        // Strip quarantine so the freshly placed copy isn't itself translocated.
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", applicationsURL.path])

        // Launch the relocated copy and exit this (translocated) instance.
        run("/usr/bin/open", ["-n", applicationsURL.path])
        NSApp.terminate(nil)
    }

    // MARK: - Duplicate copies

    /// Other registered SnippAI bundles besides the running one (and any transient
    /// translocated path). Used to warn when permission was granted to a stray copy.
    static func otherCopies() -> [URL] {
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let all = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: PermissionsService.bundleID)
        var seen = Set<String>()
        return all
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { url in
                let path = url.path
                if path == running.path { return false }
                if path.contains("/AppTranslocation/") { return false }
                return seen.insert(path).inserted
            }
    }

    /// Moves the given copies to the Trash (reversible). Best-effort.
    static func removeCopies(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls, completionHandler: nil)
    }

    // MARK: - Helpers

    private static func quitOtherInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: PermissionsService.bundleID)
        where app.processIdentifier != me {
            app.forceTerminate()
        }
    }

    private static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private static func run(_ launchPath: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
