import AppKit
import Carbon.HIToolbox
import SnippAIKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let voiceController = VoiceController()
    private let askSettings = AskSettings()
    private lazy var panelController = PanelController(model: model, voice: voiceController)
    private let captureController = CaptureController()
    private lazy var annotationOverlay = AnnotationOverlayController(capture: captureController, voice: voiceController)
    private let onboarding = OnboardingController()
    private let shortcutStore = ShortcutStore()
    private let licenseStore = LicenseStore()
    private let launchAtLoginStore = LaunchAtLoginStore()
    private let updateController = UpdateController()
    private lazy var paywallController = PaywallController()
    private lazy var hookController = HookController(model: model)
    private lazy var settings = SettingsController(store: shortcutStore, hooks: hookController, license: licenseStore, launchAtLogin: launchAtLoginStore, voice: voiceController, ask: askSettings)
    private var statusItem: NSStatusItem?
    private var captureMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var hotKey: HotKey?
    private var askHotKey: HotKey?
    /// Never invalidated by design: AppDelegate lives for the process's lifetime,
    /// and Swift 6 forbids touching a non-Sendable Timer from a nonisolated deinit.
    private var hotKeyWatchdog: Timer?
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
        // If we're running from a location where macOS can't persist permissions
        // (the DMG, Downloads, or a translocated path), move into /Applications and
        // relaunch from there. The process is terminating — stop launching.
        if InstallGuard.relocateIfNeeded() { return }

        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        CaptureController.sweepOldScreenshots()
        setupStatusItem()
        bindHotKey(to: shortcutStore.combo)
        bindAskHotKey()
        // Toggling Ask in Settings claims/releases ⌥⇧A immediately.
        askSettings.onEnabledChange = { [weak self] in self?.bindAskHotKey() }
        // Re-register live (no relaunch) whenever the user changes the shortcut, and
        // refresh the menu so it shows the new glyphs.
        shortcutStore.onChange = { [weak self] combo in
            guard let self else { return true }
            let ok = self.bindHotKey(to: combo)
            self.refreshCaptureMenuTitle()
            return ok
        }
        // Self-healing: macOS can silently drop a Carbon registration out from under
        // a live process (observed in the field 2026-07-14: healthy app, combo
        // unclaimed at the OS level, hotkey dead until relaunch). Carbon offers no
        // "is my ref still alive" query, so re-assert the binding periodically and
        // after wake — Unregister+Register of the current combo is sub-millisecond.
        hotKeyWatchdog = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reassertHotKey() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reassertHotKey() }
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

        // Lightweight update check: surfaces as a menu-bar item AND a dismissible
        // panel banner. Re-checks periodically — a menu-bar app can stay up for
        // weeks, so a launch-only check would never see releases published after launch.
        model.openUpdate = { [weak self] in self?.updateController.openDownload() }
        updateController.onChange = { [weak self] in
            self?.refreshUpdateMenuItem()
            self?.model.availableUpdateVersion = self?.updateController.available?.version
        }
        updateController.startPeriodicChecks()

        #if DEBUG
        // Debug builds only: env-var hooks for self-tests and UI screenshots. Kept out
        // of release binaries entirely — some (SNIPPAI_AUTO_PANEL, SNIPPAI_TEST_DESKTOP_
        // INJECT) reach the send path without passing the capture/paywall gate.

        // Debug: self-test the ScreenCaptureKit path on an explicit global rect.
        if let spec = ProcessInfo.processInfo.environment["SNIPPAI_TEST_CAPTURE"] {
            runCaptureSelfTest(spec)
            return
        }

        // Debug: force the onboarding window open for inspection. Pass "welcome" to
        // open on the intro carousel, anything else truthy for the permission checklist.
        if let mode = ProcessInfo.processInfo.environment["SNIPPAI_SHOW_ONBOARDING"], !mode.isEmpty {
            onboarding.show(startAt: mode == "welcome" ? .welcome : .checklist)
            return
        }

        // Debug: force the settings window open for inspection.
        if ProcessInfo.processInfo.environment["SNIPPAI_SHOW_SETTINGS"] == "1" {
            settings.show()
            return
        }
        #endif

        // First-run: guide the two macOS permission gates before the first capture.
        onboarding.showIfNeeded()

        #if DEBUG
        // Debug: show the crosshair overlay so it can be screenshotted.
        if ProcessInfo.processInfo.environment["SNIPPAI_TEST_OVERLAY"] == "1" {
            beginCapture()
        }

        // Debug: present the Ask overlay directly (bypasses the global hotkey, which
        // synthetic keystrokes deliver unreliably) with a staged annotation so the
        // card layout can be screenshotted deterministically.
        if ProcessInfo.processInfo.environment["SNIPPAI_ASK_OVERLAY"] == "1" {
            Task {
                await annotationOverlay.present()
                if let fragment = ProcessInfo.processInfo.environment["SNIPPAI_ASK_FRAGMENT"] {
                    let annotation = annotationOverlay.session?.addAnnotation(
                        anchor: CGRect(x: 120, y: 180, width: 300, height: 22), fragment: fragment)
                    if let question = ProcessInfo.processInfo.environment["SNIPPAI_ASK_QUESTION"] {
                        voiceController.cancelRecording()
                        annotation?.submit(question: question)
                    }
                }
            }
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
        #endif
    }

    #if DEBUG
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
    #endif

    /// Installs a minimal main menu with a standard Edit menu. SnippAI is an accessory
    /// app (no menu bar by default), so without this the system clipboard shortcuts
    /// (⌘C/⌘V/⌘X/⌘A) never reach text fields — e.g. pasting a license key. The menu's
    /// key equivalents are processed for the key window even while we're an accessory.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit SnippAI",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
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

    /// Ask's fixed shortcut (⌥⇧A — mnemonic "Ask"; MVP: not yet rebindable).
    /// Registered on its own Carbon id so it never collides with capture.
    /// Respects the Settings kill switch: a disabled feature must RELEASE the
    /// combo — otherwise SnippAI keeps swallowing ⌥⇧A (the Å keystroke on many
    /// layouts) system-wide while doing nothing with it.
    @discardableResult
    private func bindAskHotKey() -> Bool {
        askHotKey = nil
        guard askSettings.isEnabled else { return true }
        let combo = HotKey.KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | shiftKey))
        let key = HotKey(combo: combo, id: 2) { [weak self] in self?.beginAsk() }
        askHotKey = key
        return key.isRegistered
    }

    /// Watchdog tick: re-claim the current combo. Skipped while Settings is open —
    /// the shortcut recorder needs the combo released while listening for a new one,
    /// and a re-assert mid-recording would fight it. Known trade-off: a Settings
    /// window left open pauses the watchdog for that whole time; ticks resume (and
    /// heal any lost registration) as soon as it closes.
    private func reassertHotKey() {
        guard !settings.isOpen else { return }
        bindHotKey(to: shortcutStore.combo)
        bindAskHotKey()
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
        let howItWorksItem = NSMenuItem(title: "How It Works…", action: #selector(menuHowItWorks), keyEquivalent: "")
        howItWorksItem.target = self
        menu.addItem(howItWorksItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let setupItem = NSMenuItem(title: "Permissions…", action: #selector(menuSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        let uninstallItem = NSMenuItem(title: "Uninstall SnippAI…", action: #selector(menuUninstall), keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)
        menu.addItem(.separator())
        // Appears only when the update check finds a newer build (hidden otherwise).
        let updateItem = NSMenuItem(title: "Update SnippAI…", action: #selector(menuUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        self.updateMenuItem = updateItem
        let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(menuCheckForUpdates), keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)
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

    /// Manual update check with explicit feedback — unlike the silent background
    /// check, the user asked, so always answer (up to date / update found / failed).
    @objc private func menuCheckForUpdates() {
        Task {
            await updateController.check()
            let alert = NSAlert()
            if let update = updateController.available {
                alert.messageText = "SnippAI \(update.version) is available"
                alert.informativeText = "You're running \(updateController.currentVersion). Download the update?"
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { updateController.openDownload() }
            } else if updateController.lastCheckFailed {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "SnippAI couldn't reach the update feed. Check your connection and try again."
                alert.runModal()
            } else {
                alert.messageText = "You're up to date"
                alert.informativeText = "SnippAI \(updateController.currentVersion) is the latest version."
                alert.runModal()
            }
        }
    }

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

    @objc private func menuSetup() { onboarding.show(startAt: .checklist) }
    @objc private func menuHowItWorks() { onboarding.show(startAt: .welcome) }

    /// Confirms, then fully uninstalls SnippAI: removes its Claude Code hooks, deletes
    /// its preferences/support/cache, moves the app to the Trash, and quits — so the
    /// user never has to hunt down leftover files or broken hook entries by hand.
    @objc private func menuUninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall SnippAI?"
        alert.informativeText = """
        This removes SnippAI's Claude Code hooks, deletes its preferences and data, and moves the app to the Trash.

        Your purchase isn't affected — you can reinstall and re-activate your license any time. This can't be undone.
        """
        alert.alertStyle = .warning
        let uninstallButton = alert.addButton(withTitle: "Uninstall")
        uninstallButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.setActivationPolicy(.regular)        // ensure the modal is focusable
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        NSApp.setActivationPolicy(.accessory)
        guard choice == .alertFirstButtonReturn else { return }
        performUninstall()
    }

    private func performUninstall() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // 1. Remove our hooks from ~/.claude/settings.json FIRST (while the script still
        //    exists), so we never strand orphaned entries.
        hookController.removeHooksForUninstall()

        // 2. Delete app data: Application Support (hook script + trial mirror), prefs, cache.
        try? fm.removeItem(at: home.appendingPathComponent("Library/Application Support/SnippAI"))
        if let bid = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bid)
            try? fm.removeItem(at: home.appendingPathComponent("Library/Preferences/\(bid).plist"))
            try? fm.removeItem(at: home.appendingPathComponent("Library/Caches/\(bid)"))
        }

        // 3. Move the app bundle itself to the Trash (best-effort; a read-only or
        //    permission-restricted location just leaves the bundle for the user to drag).
        try? fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)

        // 4. Quit.
        NSApp.terminate(nil)
    }

    @objc private func menuOpenPanel() {
        // Opening the panel is a way to use the app, so it goes through the same gate as
        // capture — otherwise an expired user could bypass the paywall here.
        withLicenseGate { [weak self] in
            guard let self else { return }
            annotationOverlay.dismiss()   // opening the panel proper supersedes an ask
            Task {
                await self.model.beginSession(screenshots: self.model.screenshotURLs)
                self.panelController.show(onClose: {})
            }
        }
    }

    // MARK: - License gate

    /// Runs `proceed` if the user is in trial or licensed; otherwise shows the paywall.
    /// While grace deferrals remain, "Maybe later" lets the action through once. The
    /// single gate for every way to use the app (capture hotkey/menu/panel "+", Open Panel).
    private func withLicenseGate(_ proceed: @escaping () -> Void) {
        switch licenseStore.evaluateCapture() {
        case .allowed:
            proceed()
        case .paywall(let canDefer):
            paywallController.show(store: licenseStore, canDefer: canDefer) { ok in
                if ok { proceed() }
            }
        }
    }

    // MARK: - Capture flow

    // MARK: - Ask flow (⌥⇧A: freeze the screen → point → ask in place)

    private func beginAsk() {
        // Toggle: a second press of the hotkey dismisses the overlay. This is the
        // always-available escape hatch — a global Carbon hotkey fires regardless of
        // which view holds focus, so it works even when Esc can't reach the overlay.
        if annotationOverlay.isPresenting { annotationOverlay.dismiss(); return }
        guard !isCapturing, askSettings.isEnabled else { return }
        guard AskSettings.claudeAvailable else {
            NSSound.beep()   // no `claude` CLI — nothing to answer with
            return
        }
        withLicenseGate { [weak self] in
            Task { await self?.annotationOverlay.present() }
        }
    }

    private func beginCapture() {
        guard !isCapturing else { return }
        withLicenseGate { [weak self] in self?.performCapture() }
    }

    private func performCapture() {
        guard !isCapturing else { return }
        // A new capture supersedes any Ask in progress (the documented contract) —
        // otherwise the screenshot appends invisibly behind the Ask view.
        annotationOverlay.dismiss()
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

    #if DEBUG
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
    #endif

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
