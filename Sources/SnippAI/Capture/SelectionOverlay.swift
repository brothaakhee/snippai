import AppKit

/// Result of a region selection: the rect in global (bottom-left origin) screen
/// coordinates plus the geometry needed to capture it. Value-only so it crosses
/// concurrency boundaries safely.
struct SelectionResult: Sendable {
    let globalRect: CGRect
    let screenFrame: CGRect
    let backingScale: CGFloat
    let displayID: CGDirectDisplayID
}

/// Borderless windows can't become key by default, which would drop the Esc
/// keypress used to cancel selection. This makes the overlay keyable.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A full-screen, transparent, borderless overlay that draws a crosshair
/// selection rectangle and reports the chosen region. Owns its own window so it
/// can sit above everything (including full-screen apps).
@MainActor
final class SelectionOverlayController {
    private var windows: [NSWindow] = []
    private var completion: ((SelectionResult?) -> Void)?

    /// Presents the crosshair across all screens. `completion` receives the
    /// selection, or `nil` if the user cancels (Esc / click without drag).
    func begin(completion: @escaping (SelectionResult?) -> Void) {
        self.completion = completion
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenRef = screen
            // Debug: seed a demo selection so the full overlay UI can be screenshotted.
            if screen == NSScreen.main, ProcessInfo.processInfo.environment["SNIPPAI_DEMO_RECT"] == "1" {
                let f = screen.frame.size
                view.demoRect = NSRect(x: f.width * 0.28, y: f.height * 0.30,
                                       width: f.width * 0.42, height: f.height * 0.34)
            }
            view.onFinish = { [weak self] result in self?.finish(result) }
            view.onCancel = { [weak self] in self?.finish(nil) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            DispatchQueue.main.async { window.makeFirstResponder(view) }
        }
    }

    private func finish(_ result: SelectionResult?) {
        let completion = self.completion
        self.completion = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        completion?(result)
    }
}

@MainActor
private final class SelectionView: NSView {
    weak var screenRef: NSScreen?
    var onFinish: ((SelectionResult) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    var demoRect: NSRect? { didSet { if let demoRect { currentRect = demoRect; needsDisplay = true } } }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        // Clamp the live point to the view so a drag past the display edge can't
        // produce a selection that extends off the captured display.
        let raw = convert(event.locationInWindow, from: nil)
        let p = NSPoint(x: min(max(raw.x, bounds.minX), bounds.maxX),
                        y: min(max(raw.y, bounds.minY), bounds.maxY))
        currentRect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                             width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil; currentRect = .zero; needsDisplay = true }
        // Snap to integer points so the displayed badge and the produced image agree.
        let rect = currentRect.integral
        guard let screen = screenRef, let displayID = screen.displayID,
              rect.width >= 4, rect.height >= 4 else {
            onCancel?()
            return
        }
        // Convert view-local (bottom-left) rect to global screen coordinates.
        let globalRect = CGRect(x: screen.frame.minX + rect.minX,
                                y: screen.frame.minY + rect.minY,
                                width: rect.width, height: rect.height)
        onFinish?(SelectionResult(globalRect: globalRect, screenFrame: screen.frame,
                                  backingScale: screen.backingScaleFactor, displayID: displayID))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Esc
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim the whole screen so the selection clearly pops.
        NSColor.black.withAlphaComponent(0.40).setFill()
        bounds.fill()

        // Before any drag, show a centered instruction so the controls are discoverable.
        if currentRect.width <= 0 || currentRect.height <= 0 {
            drawCenteredHint("Drag to select an area  ·  Esc to cancel")
            return
        }

        // Punch a clear hole for the selection so the user sees true pixels.
        if let ctx = NSGraphicsContext.current {
            ctx.compositingOperation = .copy
            NSColor.clear.setFill()
            currentRect.fill()
            ctx.compositingOperation = .sourceOver
        }

        // Selection border (accent is reserved for this — not the badge).
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: currentRect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.5
        border.stroke()

        // Dimension chip: neutral dark, centered under the selection.
        let label = "\(Int(currentRect.width)) × \(Int(currentRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        let padding: CGFloat = 6
        var badgeRect = NSRect(x: currentRect.midX - (size.width + padding * 2) / 2,
                               y: currentRect.minY - size.height - padding - 8,
                               width: size.width + padding * 2,
                               height: size.height + padding)
        if badgeRect.minY < bounds.minY { badgeRect.origin.y = currentRect.maxY + 8 }
        drawChip(badgeRect)
        label.draw(at: NSPoint(x: badgeRect.minX + padding, y: badgeRect.minY + padding / 2), withAttributes: attrs)
    }

    private func drawChip(_ rect: NSRect) {
        let chip = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor(white: 0, alpha: 0.78).setFill()
        chip.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        chip.stroke()
    }

    private func drawCenteredHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 12
        let rect = NSRect(x: bounds.midX - (size.width + pad * 2) / 2,
                          y: bounds.midY - (size.height + pad) / 2,
                          width: size.width + pad * 2, height: size.height + pad)
        drawChip(rect)
        text.draw(at: NSPoint(x: rect.minX + pad, y: rect.minY + pad / 2), withAttributes: attrs)
    }
}
