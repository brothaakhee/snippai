import AppKit
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case noMatchingDisplay
    case captureFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "SnippAI needs Screen Recording permission. Enable it in System Settings → Privacy & Security → Screen Recording, then relaunch."
        case .noMatchingDisplay: return "Could not find the display for the selection."
        case .captureFailed(let m): return "Screen capture failed: \(m)"
        case .writeFailed(let m): return "Could not save the screenshot: \(m)"
        }
    }
}

/// Captures a selected screen region via ScreenCaptureKit and writes it to a PNG.
@MainActor
final class CaptureController {
    private let overlay = SelectionOverlayController()

    static var screenshotDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SnippAI", isDirectory: true)
    }

    /// Deletes screenshots older than `maxAge` so the temp dir doesn't grow without
    /// bound. Call at launch. The path is sent to Claude, so we keep recent files.
    static func sweepOldScreenshots(maxAge: TimeInterval = 6 * 3600) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: screenshotDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: file) }
        }
    }

    struct CaptureOutcome { let url: URL; let globalRect: CGRect }

    /// Runs the full capture flow: crosshair → region → PNG on disk.
    /// Returns `nil` if the user cancels the selection.
    func captureRegion() async throws -> CaptureOutcome? {
        let selection: SelectionResult? = await withCheckedContinuation { cont in
            overlay.begin { cont.resume(returning: $0) }
        }
        guard let selection else { return nil }
        let url = try await capture(selection)
        return CaptureOutcome(url: url, globalRect: selection.globalRect)
    }

    /// Captures an explicit global rect on a screen (used for self-tests).
    func captureGlobalRect(_ rect: CGRect, on screen: NSScreen) async throws -> URL {
        guard let displayID = screen.displayID else { throw CaptureError.noMatchingDisplay }
        let selection = SelectionResult(globalRect: rect, screenFrame: screen.frame,
                                        backingScale: screen.backingScaleFactor, displayID: displayID)
        return try await capture(selection)
    }

    private func capture(_ selection: SelectionResult) async throws -> URL {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.permissionDenied
        }

        guard let scDisplay = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw CaptureError.noMatchingDisplay
        }

        let screenFrame = selection.screenFrame
        let scale = selection.backingScale
        // Convert global (bottom-left) rect → display-local top-left points, then
        // clamp to the display so an off-edge selection can't request pixels the
        // display doesn't have.
        let raw = CGRect(
            x: selection.globalRect.minX - screenFrame.minX,
            y: screenFrame.maxY - selection.globalRect.maxY,
            width: selection.globalRect.width,
            height: selection.globalRect.height
        )
        let local = raw.intersection(CGRect(origin: .zero, size: screenFrame.size))
        guard !local.isNull, local.width >= 1, local.height >= 1 else {
            throw CaptureError.captureFailed("selection is outside the display")
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int((local.width * scale).rounded())
        config.height = Int((local.height * scale).rounded())
        config.scalesToFit = false
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }

        return try write(image)
    }

    private func write(_ image: CGImage) throws -> URL {
        let dir = Self.screenshotDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shot-\(UUID().uuidString).png")

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.writeFailed("could not create PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.writeFailed("could not finalize PNG")
        }
        return url
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
