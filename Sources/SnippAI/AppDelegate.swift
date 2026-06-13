import AppKit
import SnippAIKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private lazy var panelController = PanelController(model: model)
    private let captureController = CaptureController()
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private let combo = HotKey.KeyCombo.defaultCombo
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        CaptureController.sweepOldScreenshots()
        setupStatusItem()
        hotKey = HotKey(combo: combo) { [weak self] in
            self?.beginCapture()
        }

        // Debug: self-test the ScreenCaptureKit path on an explicit global rect.
        if let spec = ProcessInfo.processInfo.environment["SNIPPAI_TEST_CAPTURE"] {
            runCaptureSelfTest(spec)
            return
        }

        // Debug: show the crosshair overlay so it can be screenshotted.
        if ProcessInfo.processInfo.environment["SNIPPAI_TEST_OVERLAY"] == "1" {
            beginCapture()
        }

        // Debug: auto-open the panel (optionally with a sample screenshot) so the
        // UI can be inspected/screenshotted without driving the capture flow.
        if ProcessInfo.processInfo.environment["SNIPPAI_AUTO_PANEL"] == "1" {
            let sample = ProcessInfo.processInfo.environment["SNIPPAI_SAMPLE_SHOT"]
                .map { URL(fileURLWithPath: $0) }
            Task {
                await model.beginSession(screenshot: sample)
                panelController.show(onClose: {})
            }
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnippAI")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let captureItem = NSMenuItem(title: "Capture & Send  (\(combo.displayString))",
                                     action: #selector(menuCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        let panelItem = NSMenuItem(title: "Open Panel", action: #selector(menuOpenPanel), keyEquivalent: "")
        panelItem.target = self
        menu.addItem(panelItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit SnippAI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        item.menu = menu
        self.statusItem = item
    }

    @objc private func menuCapture() { beginCapture() }

    @objc private func menuOpenPanel() {
        Task {
            await model.beginSession(screenshot: model.screenshotURL)
            panelController.show(onClose: {})
        }
    }

    // MARK: - Capture flow

    private func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        // Hide the panel during selection so it isn't captured or in the way.
        panelController.hide()
        Task {
            defer { isCapturing = false }
            do {
                guard let outcome = try await captureController.captureRegion() else { return } // cancelled
                await model.beginSession(screenshot: outcome.url)
                // Place the panel beside the captured region so it doesn't cover it.
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
        let alert = NSAlert()
        alert.messageText = "SnippAI couldn't capture"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        if case CaptureError.permissionDenied = error {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.runModal()
        }
    }
}
