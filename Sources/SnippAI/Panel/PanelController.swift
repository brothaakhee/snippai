import AppKit
import SwiftUI

/// A borderless, floating panel that can accept keyboard input (so the user can
/// type a message) while staying above other windows.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class PanelController {
    private var panel: KeyablePanel?
    private let model: AppModel
    private var onClose: () -> Void = {}

    init(model: AppModel) {
        self.model = model
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
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.borderless, .nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false)
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
