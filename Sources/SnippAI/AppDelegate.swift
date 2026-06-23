import AppKit
import SnippAIKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private lazy var panelController = PanelController(model: model)
    private let captureController = CaptureController()
    private let onboarding = OnboardingController()
    private let shortcutStore = ShortcutStore()
    private let licenseStore = LicenseStore()
    private let updateController = UpdateController()
    private lazy var paywallController = PaywallController()
    private lazy var hookController = HookController(model: model)
    private lazy var settings = SettingsController(store: shortcutStore, hooks: hookController, license: licenseStore)
    private var statusItem: NSStatusItem?
    private var captureMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var hotKey: HotKey?
    private var isCapturing = false

    /// A small colored dot overlaid on the menu-bar icon when a tracked session
    /// needs attention (finished / waiting). A subview keeps the base symbol a
    /// template that still adapts to the menu bar's appearance.
    private lazy var attentionDot: NSView = {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemOrange.cgColor
        v.layer?.cornerRadius = 3
        v.isHidden = true
        return v
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        CaptureController.sweepOldScreenshots()
        setupStatusItem()
        bindHotKey(to: shortcutStore.combo)
        // Re-register live (no relaunch) whenever the user changes the shortcut, and
        // refresh the menu so it shows the new glyphs.
        shortcutStore.onChange = { [weak self] combo in
            guard let self else { return true }
            let ok = self.bindHotKey(to: combo)
            self.refreshCaptureMenuTitle()
            return ok
        }
        onboarding.shortcutDisplayProvider = { [weak self] in
            self?.shortcutStore.combo.displayString ?? "⌥⇧4"
        }
        // The panel's "+" runs the same capture flow (which appends when open).
        panelController.onAddScreenshot = { [weak self] in self?.beginCapture() }

        // Light up the menu-bar dot when a tracked session needs attention, and
        // bring the hook listener back if the user enabled it previously.
        model.onAttentionChange = { [weak self] needs in self?.updateAttentionDot(needs) }
        hookController.startIfEnabled()

        // Re-check the stored license against Lemon Squeezy on launch (silent when
        // offline — the cached verdict + grace window keep licensed users working).
        Task { await licenseStore.revalidateInBackground() }

        // Lightweight update check: show a menu item if a newer build is published.
        updateController.onChange = { [weak self] in self?.refreshUpdateMenuItem() }
        updateController.checkInBackground()

        // Debug: self-test the ScreenCaptureKit path on an explicit global rect.
        if let spec = ProcessInfo.processInfo.environment["SNIPPAI_TEST_CAPTURE"] {
            runCaptureSelfTest(spec)
            return
        }

        // Debug: force the onboarding window open for inspection.
        if ProcessInfo.processInfo.environment["SNIPPAI_SHOW_ONBOARDING"] == "1" {
            onboarding.show()
            return
        }

        // Debug: force the settings window open for inspection.
        if ProcessInfo.processInfo.environment["SNIPPAI_SHOW_SETTINGS"] == "1" {
            settings.show()
            return
        }

        // First-run: guide the two macOS permission gates before the first capture.
        onboarding.showIfNeeded()

        // Debug: show the crosshair overlay so it can be screenshotted.
        if ProcessInfo.processInfo.environment["SNIPPAI_TEST_OVERLAY"] == "1" {
            beginCapture()
        }

        // Debug: auto-open the panel (optionally with a sample screenshot) so the
        // UI can be inspected/screenshotted without driving the capture flow.
        if ProcessInfo.processInfo.environment["SNIPPAI_AUTO_PANEL"] == "1" {
            let samples = (ProcessInfo.processInfo.environment["SNIPPAI_SAMPLE_SHOT"] ?? "")
                .split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            Task {
                await model.beginSession(screenshots: samples)
                // Debug: mirror a specific real transcript as native chat so it can be
                // screenshotted without a live hook/turn.
                if let path = ProcessInfo.processInfo.environment["SNIPPAI_MIRROR_TRANSCRIPT"], !path.isEmpty {
                    model.debugMirrorTranscript(path: path)
                }
                panelController.show(onClose: {})
            }
        }

        // Debug: end-to-end desktop inject. Discovers the foreground desktop session
        // and sends a test message through the real adapter path, then exits — so the
        // inject mechanism can be verified against the live Claude app (observe the
        // session's transcript JSONL). Usage: SNIPPAI_TEST_DESKTOP_INJECT="<message>"
        if let msg = ProcessInfo.processInfo.environment["SNIPPAI_TEST_DESKTOP_INJECT"], !msg.isEmpty {
            Task { await runDesktopInjectSelfTest(msg) }
        }
    }

    /// Discovers the Claude desktop session and injects `message` via the live path.
    /// Writes the outcome to /tmp/snippai-inject-test.log (GUI-app stdout isn't a tty).
    private func runDesktopInjectSelfTest(_ message: String) async {
        func report(_ line: String) {
            try? (line + "\n").write(toFile: "/tmp/snippai-inject-test.log", atomically: true, encoding: .utf8)
        }
        if !PermissionsService.isAccessibilityTrusted() {
            PermissionsService.requestAccessibility()
            report("DESKTOP_INJECT_FAIL accessibility-not-granted (prompted; grant SnippAI then re-run)")
            return
        }
        // Debug: simulate "user was on Chrome" so the focus-restore can be verified.
        if let app = ProcessInfo.processInfo.environment["SNIPPAI_TEST_RETURN_TO"] {
            DesktopInjector.returnToApp = NSRunningApplication
                .runningApplications(withBundleIdentifier: app).first
        }
        let desktop = ClaudeDesktopAdapter(inject: DesktopInjector.make())
        do {
            let sessions = try await desktop.discover()   // already sorted most-recently-focused first
            let pin = ProcessInfo.processInfo.environment["SNIPPAI_TEST_DESKTOP_SESSION"]
            guard let target = (pin.flatMap { id in sessions.first { $0.id == id } }) ?? sessions.first else {
                report("DESKTOP_INJECT_FAIL no-desktop-session"); return
            }
            try await desktop.send(text: message, toSession: target.id)
            report("DESKTOP_INJECT_OK target=\(target.id) cwd=\(target.cwd)")
        } catch {
            report("DESKTOP_INJECT_FAIL \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }

    // MARK: - Global hotkey

    /// (Re)registers the global capture hotkey, releasing any prior registration
    /// first so the two never collide on the same Carbon hotkey ID. Returns whether
    /// the OS accepted the combo.
    @discardableResult
    private func bindHotKey(to combo: HotKey.KeyCombo) -> Bool {
        hotKey = nil   // release old Carbon registration before claiming the new combo
        let key = HotKey(combo: combo) { [weak self] in self?.beginCapture() }
        hotKey = key
        return key.isRegistered
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnippAI")
            button.image?.isTemplate = true
            button.addSubview(attentionDot)
        }
        let menu = NSMenu()
        let captureItem = NSMenuItem(title: captureMenuTitle, action: #selector(menuCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        self.captureMenuItem = captureItem
        let panelItem = NSMenuItem(title: "Open Panel", action: #selector(menuOpenPanel), keyEquivalent: "")
        panelItem.target = self
        menu.addItem(panelItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let setupItem = NSMenuItem(title: "Permissions…", action: #selector(menuSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        menu.addItem(.separator())
        // Appears only when the update check finds a newer build (hidden otherwise).
        let updateItem = NSMenuItem(title: "Update SnippAI…", action: #selector(menuUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        self.updateMenuItem = updateItem
        let quitItem = NSMenuItem(title: "Quit SnippAI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        item.menu = menu
        self.statusItem = item
        refreshUpdateMenuItem()
    }

    /// Shows/hides the "Update SnippAI" menu item based on the latest check.
    private func refreshUpdateMenuItem() {
        guard let item = updateMenuItem else { return }
        if let update = updateController.available {
            item.title = "Update to SnippAI \(update.version)…"
            item.isHidden = false
        } else {
            item.isHidden = true
        }
    }

    @objc private func menuUpdate() { updateController.openDownload() }

    private var captureMenuTitle: String { "Capture & Send  (\(shortcutStore.combo.displayString))" }

    private func refreshCaptureMenuTitle() { captureMenuItem?.title = captureMenuTitle }

    /// Shows/hides the attention dot at the top-right of the menu-bar icon.
    private func updateAttentionDot(_ needs: Bool) {
        attentionDot.isHidden = !needs
        if needs, let b = statusItem?.button {
            attentionDot.frame.origin = NSPoint(x: b.bounds.width - 8, y: b.bounds.height - 8)
        }
    }

    @objc private func menuCapture() { beginCapture() }

    @objc private func menuSettings() { settings.show() }

    @objc private func menuSetup() { onboarding.show() }

    @objc private func menuOpenPanel() {
        Task {
            await model.beginSession(screenshots: model.screenshotURLs)
            panelController.show(onClose: {})
        }
    }

    // MARK: - Capture flow

    private func beginCapture() {
        guard !isCapturing else { return }
        // Trial/paywall gate — the single choke point for every capture entry (hotkey,
        // menu, panel "+"). Once the trial is over, capturing prompts the paywall; the
        // user may "Maybe later" past it a limited number of times, then a license is
        // required. In-trial and licensed users pass straight through.
        switch licenseStore.evaluateCapture() {
        case .allowed:
            performCapture()
        case .paywall(let canDefer):
            paywallController.show(store: licenseStore, canDefer: canDefer) { [weak self] proceed in
                if proceed { self?.performCapture() }
            }
        }
    }

    private func performCapture() {
        guard !isCapturing else { return }
        // If we'd be appending to an open draft that's already at the cap, don't make
        // the user drag out a region that gets discarded — give audible feedback.
        if panelController.isVisible && !model.canAddScreenshot {
            NSSound.beep()
            return
        }
        isCapturing = true
        // Remember the app the user is on right now (before our overlay/panel grabs
        // focus), so a desktop-app inject can return them here afterward. Only on a
        // fresh capture — an accumulate keeps the original return target.
        if !panelController.isVisible {
            DesktopInjector.returnToApp = NSWorkspace.shared.frontmostApplication
        }
        // Note: we deliberately DON'T hide the panel here — the crosshair overlay
        // sits above it, so the user can re-capture (or capture the panel itself)
        // without it vanishing. They can drag the panel aside if it's in the way.
        Task {
            defer { isCapturing = false }
            do {
                guard let outcome = try await captureController.captureRegion() else { return } // cancelled
                // If the panel is already open, accumulate this shot into the current
                // draft (keep the typed message + target); otherwise start fresh.
                if panelController.isVisible {
                    model.addScreenshot(outcome.url)
                } else {
                    await model.beginSession(screenshots: [outcome.url])
                }
                panelController.show(besideSelection: outcome.globalRect, onClose: {})
            } catch {
                presentError(error)
            }
        }
    }

    /// Captures `x,y,w,h` (global, bottom-left coords) on the main screen, prints
    /// the result path, and exits — used to verify the capture path headlessly.
    private func runCaptureSelfTest(_ spec: String) {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, let screen = NSScreen.main else {
            print("CAPTURE_TEST_FAIL bad spec"); NSApp.terminate(nil); return
        }
        let rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        Task {
            do {
                let url = try await captureController.captureGlobalRect(rect, on: screen)
                print("CAPTURE_SAVED \(url.path)")
            } catch {
                print("CAPTURE_TEST_FAIL \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            NSApp.terminate(nil)
        }
    }

    private func presentError(_ error: Error) {
        // A missing capture permission is exactly what onboarding exists to fix —
        // send the user there instead of a dead-end alert.
        if case CaptureError.permissionDenied = error {
            onboarding.show()
            return
        }
        let alert = NSAlert()
        alert.messageText = "SnippAI couldn't capture"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
