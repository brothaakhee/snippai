import AppKit
import SwiftUI

/// A borderless, floating panel that can accept keyboard input (so the user can
/// type a message) while staying above other windows.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: KeyablePanel?
    private let model: AppModel
    private let voice: VoiceController
    private var onClose: () -> Void = {}
    /// Invoked by the panel's "+" button to capture and append another screenshot.
    var onAddScreenshot: () -> Void = {}

    /// Whether the panel is currently on screen (so a new capture knows to append
    /// to the open draft vs. start fresh).
    var isVisible: Bool { panel?.isVisible ?? false }

    private static let widthKey = "panelWidth"
    private static let heightKey = "panelHeight"
    private static let opacityKey = "panelOpacity"
    private static let defaultSize = NSSize(width: 540, height: 600)
    private static let minSize = NSSize(width: 420, height: 420)
    /// The panel never fades fully invisible — at the floor it's still visible and
    /// grabbable. (alphaValue doesn't affect hit-testing, so it stays clickable too.)
    private static let minOpacity = 0.2

    init(model: AppModel, voice: VoiceController) {
        self.model = model
        self.voice = voice
        super.init()
    }

    /// The persisted panel size, clamped to the minimum (and sane defaults on first run).
    private var savedSize: NSSize {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.widthKey) != nil else { return Self.defaultSize }
        return NSSize(
            width: max(Self.minSize.width, CGFloat(d.double(forKey: Self.widthKey))),
            height: max(Self.minSize.height, CGFloat(d.double(forKey: Self.heightKey))))
    }

    /// The persisted panel opacity, clamped to `[minOpacity, 1]` (and fully opaque on
    /// first run). Read with an `object(forKey:)` presence check — a bare
    /// `double(forKey:)` returns 0.0 for a missing key, which would open a fresh
    /// install invisible.
    private var savedOpacity: Double {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.opacityKey) != nil else { return 1.0 }
        return min(1.0, max(Self.minOpacity, d.double(forKey: Self.opacityKey)))
    }

    /// (Re)applies the saved opacity to the live panel. Called at build time and on
    /// every `show()` so a value changed while hidden always takes — the panel is
    /// built once and reused, so a one-time set at build would otherwise stick.
    private func applyOpacity() {
        panel?.alphaValue = CGFloat(savedOpacity)
    }

    /// Live-updates the panel opacity from the slider and persists it. Clamped as a
    /// final safety net; set directly (no animation) so dragging feels immediate.
    func setOpacity(_ value: Double) {
        let v = min(1.0, max(Self.minOpacity, value))
        UserDefaults.standard.set(v, forKey: Self.opacityKey)
        panel?.alphaValue = CGFloat(v)
    }

    /// Persist the panel's size after the user finishes a drag-resize, so it's
    /// restored next time the panel opens.
    nonisolated func windowDidEndLiveResize(_ notification: Notification) {
        // AppKit delivers window-delegate callbacks on the main thread. Read our own
        // panel (Sendable via @MainActor self) rather than the non-Sendable notification.
        MainActor.assumeIsolated {
            guard let size = panel?.frame.size else { return }
            let d = UserDefaults.standard
            d.set(Double(size.width), forKey: Self.widthKey)
            d.set(Double(size.height), forKey: Self.heightKey)
        }
    }

    func show(besideSelection rect: CGRect? = nil, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let panel = existingOrNewPanel()
        // Only (re)position on a fresh open — never on an append-capture, so a panel
        // the user dragged aside (or is typing in) doesn't get yanked back.
        if !panel.isVisible { positionPanel(panel, besideSelection: rect) }
        // Re-apply the saved opacity before showing, so it's in effect with no
        // full-alpha flash even if it changed while the panel was hidden.
        applyOpacity()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Voice-first on REOPEN too: the hosting view stays mounted across
        // hide/show, so ComposeView.onAppear never re-fires — without this, auto-
        // listen would work only on the panel's very first open. Idempotent: it's
        // a no-op unless voice is idle-ready and we're composing.
        if model.phase == .composing {
            Task { await voice.beginRecording() }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        // Stop the live mirror streams — a hidden panel must not keep fetching and
        // rendering screen buffers in the background. `beginSession` restarts them
        // on the next open. Likewise the mic: a hidden panel must never listen.
        model.teardown()
        voice.cancelRecording()
    }

    private func existingOrNewPanel() -> KeyablePanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: PanelView(model: model, voice: voice, onClose: { [weak self] in
            self?.hide()
            self?.onClose()
        }, onAddScreenshot: { [weak self] in
            self?.onAddScreenshot()
        }, initialOpacity: savedOpacity, onOpacityChange: { [weak self] in
            self?.setOpacity($0)
        }))
        hosting.sizingOptions = []
        let size = savedSize
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false)
        panel.minSize = Self.minSize
        panel.delegate = self
        // Always dark, regardless of the system appearance, so AppKit-drawn bits
        // (text cursor, scrollers, input text) match the flat dark SwiftUI surface.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        self.panel = panel
        applyOpacity()
        return panel
    }

    private func positionPanel(_ panel: NSWindow, besideSelection rect: CGRect?) {
        let size = panel.frame.size
        // Always center the panel — on the display where the capture happened (so it
        // lands on the right monitor in a multi-display setup), else the main screen.
        let anchor = rect.map { CGPoint(x: $0.midX, y: $0.midY) }
        let screen = NSScreen.screens.first { s in anchor.map { s.frame.contains($0) } ?? false }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        panel.setFrameOrigin(origin)
    }
}
