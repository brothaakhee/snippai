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
    private var onClose: () -> Void = {}
    /// Invoked by the panel's "+" button to capture and append another screenshot.
    var onAddScreenshot: () -> Void = {}

    /// Whether the panel is currently on screen (so a new capture knows to append
    /// to the open draft vs. start fresh).
    var isVisible: Bool { panel?.isVisible ?? false }

    private static let widthKey = "panelWidth"
    private static let heightKey = "panelHeight"
    private static let defaultSize = NSSize(width: 540, height: 600)
    private static let minSize = NSSize(width: 420, height: 420)

    init(model: AppModel) {
        self.model = model
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
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func existingOrNewPanel() -> KeyablePanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: PanelView(model: model, onClose: { [weak self] in
            self?.hide()
            self?.onClose()
        }, onAddScreenshot: { [weak self] in
            self?.onAddScreenshot()
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
