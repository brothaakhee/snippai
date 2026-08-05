import AppKit
import SwiftUI
import SnippAIKit

/// Presents the in-place Ask overlay: freezes the screen, lays a transparent
/// annotation layer over it, and lets the user point at parts of the response
/// and ask about them without leaving their terminal/app.
@MainActor
final class AnnotationOverlayController: NSObject {
    private var panel: KeyablePanel?
    private let capture: CaptureController
    private let voice: VoiceController
    private(set) var session: AnnotationSession?
    /// Local key monitor that guarantees Escape dismisses the overlay no matter
    /// which subview (mic, text field) holds focus — SwiftUI's `.onExitCommand`
    /// only fires for the first responder, so a focused text field would eat Esc.
    private var keyMonitor: Any?

    /// True while the overlay is on screen (so the hotkey doesn't re-enter).
    var isPresenting: Bool { panel != nil }

    init(capture: CaptureController, voice: VoiceController) {
        self.capture = capture
        self.voice = voice
        super.init()
    }

    /// Freezes the screen and shows the overlay. No-op if already up.
    func present() async {
        guard panel == nil else { return }
        guard let screen = NSScreen.main else { return }

        // Grab the backdrop BEFORE showing anything, so we don't capture ourselves.
        // If Screen Recording isn't granted, fall back to a dark backdrop so the
        // overlay still appears (the selection/clipboard path still works) rather
        // than silently doing nothing.
        let backdrop: CGImage
        var captureFailed = false
        do {
            backdrop = try await capture.captureFullScreen(screen)
        } catch {
            backdrop = Self.solidBackdrop()
            captureFailed = true
        }

        let session = AnnotationSession(backdrop: backdrop, backdropSize: screen.frame.size)
        self.session = session

        let root = AnnotationOverlayView(
            session: session, voice: voice, captureUnavailable: captureFailed,
            recognize: { [weak self] rect in await self?.recognize(rect, on: screen) ?? "" },
            onClose: { [weak self] in self?.dismiss() })

        let panel = KeyablePanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .screenSaver               // above the panel + most everything
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: root)
        panel.setFrame(screen.frame, display: true)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Escape / ⌘. always dismisses — the monitor sees the keyDown before it
        // reaches any focused text field, so the overlay can never trap the screen.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53
            let isCmdPeriod = event.charactersIgnoringModifiers == "." && event.modifierFlags.contains(.command)
            guard isEscape || isCmdPeriod else { return event }
            self?.dismiss()
            return nil   // swallow it
        }

        // If the user already had text selected, skip straight to asking — anchor
        // the thread where the cursor was (that's what they were pointing at).
        let selection = await SelectionGrabber.grab()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selection, !selection.isEmpty {
            let mouse = NSEvent.mouseLocation
            let point = CGPoint(x: mouse.x - screen.frame.minX,
                                y: screen.frame.maxY - mouse.y)   // → top-left view coords
            let anchor = CGRect(x: max(0, point.x - 120), y: point.y + 8, width: 240, height: 20)
            await session.addAnnotation(anchor: anchor, fragment: selection)
        } else if captureFailed {
            // No live backdrop to drag/OCR AND nothing pre-selected → the overlay
            // is a dead end. Don't strand the user: guide them to Screen Recording.
            dismiss()
            NSSound.beep()
            PermissionsService.openScreenRecordingSettings()
        }
    }

    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        voice.cancelRecording()
        session?.clear()
        session = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// A plain dark backdrop for when Screen Recording isn't granted.
    private static func solidBackdrop() -> CGImage {
        let w = 8, h = 8
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// OCR one region of the frozen screen. `rect` is in screen points (top-left
    /// origin, matching the SwiftUI overlay); we scale into backdrop pixels.
    private func recognize(_ rect: CGRect, on screen: NSScreen) async -> String {
        guard let backdrop = session?.backdrop else { return "" }
        // Independent axes: the captured backdrop's pixel size can diverge from
        // frame × backingScale on scaled/secondary display modes, so a single scale
        // would OCR the wrong strip vertically.
        let sx = CGFloat(backdrop.width) / screen.frame.width
        let sy = CGFloat(backdrop.height) / screen.frame.height
        let pixelRect = CGRect(x: rect.minX * sx, y: rect.minY * sy,
                               width: rect.width * sx, height: rect.height * sy)
            .integral
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = backdrop.cropping(to: pixelRect) else { return "" }
        return await Task.detached {
            (try? TextRecognizer.recognize(in: cropped)) ?? ""
        }.value
    }
}
