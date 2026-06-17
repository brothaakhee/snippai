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

    private static let widthKey = "panelWidth"
    private static let heightKey = "panelHeight"
    private static let defaultSize = NSSize(width: 420, height: 560)
    private static let minSize = NSSize(width: 360, height: 360)

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
        positionPanel(panel, besideSelection: rect)
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
        }))
        hosting.sizingOptions = []
        let size = savedSize
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false)
        panel.minSize = Self.minSize
        panel.delegate = self
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
        let anchor = rect.map { CGPoint(x: $0.midX, y: $0.midY) }
        let screen = NSScreen.screens.first { s in anchor.map { s.frame.contains($0) } ?? false }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let gap: CGFloat = 16

        var origin: CGPoint
        if let rect {
            // Prefer placing to the right of the selection; fall back to left,
            // then below, then above — whichever fits — so the capture stays visible.
            let centeredY = rect.midY - size.height / 2
            if rect.maxX + gap + size.width <= visible.maxX {            // right
                origin = CGPoint(x: rect.maxX + gap, y: centeredY)
            } else if rect.minX - gap - size.width >= visible.minX {     // left
                origin = CGPoint(x: rect.minX - gap - size.width, y: centeredY)
            } else if rect.minY - gap - size.height >= visible.minY {    // below
                origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - gap - size.height)
            } else {                                                     // above
                origin = CGPoint(x: rect.midX - size.width / 2, y: rect.maxY + gap)
            }
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)
        panel.setFrameOrigin(origin)
    }
}
