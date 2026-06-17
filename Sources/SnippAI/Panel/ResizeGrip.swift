import SwiftUI
import AppKit

/// The classic bottom-right "grow box" affordance: a few diagonal hatch lines the
/// user can drag to resize the panel. The window is already `.resizable` (so edges
/// drag too), but a visible grip makes resizing discoverable.
struct ResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeGripView { ResizeGripView() }
    func updateNSView(_ nsView: ResizeGripView, context: Context) {}
}

final class ResizeGripView: NSView {
    private var initialFrame: NSRect = .zero
    private var initialMouse: NSPoint = .zero

    // Without this, isMovableByWindowBackground would treat a grip-drag as a window
    // *move* instead of letting us resize.
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.secondaryLabelColor.withAlphaComponent(0.7).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        // Three parallel 45° segments joining the bottom and right edges near the
        // corner — the universally recognized "resize corner" look.
        for off in [CGFloat(4), 9, 14] {
            path.move(to: NSPoint(x: bounds.maxX - off, y: bounds.minY + 2))
            path.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + off))
        }
        path.stroke()
    }

    override func resetCursorRects() {
        // No public diagonal-resize cursor; the crosshair at least signals "draggable".
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialFrame = window.frame
        initialMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - initialMouse.x
        let dy = now.y - initialMouse.y   // screen y is up, so dragging down is negative
        let newWidth = max(window.minSize.width, initialFrame.width + dx)
        let newHeight = max(window.minSize.height, initialFrame.height - dy)
        // Resize from the bottom-right: keep the top-left corner pinned.
        let origin = NSPoint(x: initialFrame.minX, y: initialFrame.maxY - newHeight)
        window.setFrame(NSRect(origin: origin, size: NSSize(width: newWidth, height: newHeight)),
                        display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else { return }
        // setFrame() doesn't fire the live-resize delegate, so persist explicitly by
        // reusing the controller's existing save path.
        window.delegate?.windowDidEndLiveResize?(
            Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
    }
}
