import Foundation
import Observation
import SnippAIKit

/// Drives voice input end to end: the opt-in + model download (Settings), the
/// mic session (panel), and transcription. Voice is a layer over the text input —
/// the transcript lands in the message field for review; it never sends by itself.
@MainActor
@Observable
final class VoiceController {
    enum Phase: Equatable {
        case disabled                 // setting off
        case downloading(Double)      // fetching models (fraction 0…1)
        case preparing                // loading/compiling models (first time can take ~2 min)
        case ready                    // idle, mic available
        case recording
        case transcribing

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    private(set) var phase: Phase = .disabled
    /// User-facing note (mic denied, download failed…) for Settings + the panel.
    private(set) var statusMessage: String?
    var level: Float { recorder.level }
    var isEnabled: Bool {
        guard case .disabled = phase else { return true }
        return false
    }

    private let transcriber = VoiceTranscriber()
    private let recorder = MicRecorder()
    private var prepareTask: Task<Void, Never>?
    private static let enabledKey = "voice.enabled"

    init() {
        // The engine can die silently mid-recording (mic unplugged, AirPods
        // switch) — surface it instead of a frozen "Listening…".
        recorder.onInterrupted = { [weak self] in
            guard let self, phase == .recording else { return }
            phase = .ready
            statusMessage = "The microphone changed or disconnected — click the mic to start again."
        }
        // Re-arm quietly on launch if the user enabled voice before. Models are
        // normally cached (0.4 s load); if they vanished, this re-downloads with
        // progress visible in Settings.
        if UserDefaults.standard.bool(forKey: Self.enabledKey) {
            prepareTask = Task { await prepare() }
        }
    }

    // MARK: - Enablement (Settings)

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        statusMessage = nil
        if on {
            prepareTask = Task { await prepare() }
        } else {
            prepareTask?.cancel()
            recorder.cancel()
            phase = .disabled
        }
    }

    /// Download (if needed) + load the models, reporting progress into `phase`.
    private func prepare() async {
        let cached = VoiceTranscriber.modelsCached(in: VoiceTranscriber.defaultModelsDirectory)
        phase = cached ? .preparing : .downloading(0)
        do {
            try await transcriber.load { fraction in
                Task { @MainActor [weak self] in
                    // Download progress only applies while we're still downloading.
                    if case .downloading = self?.phase { self?.phase = .downloading(fraction) }
                }
            }
            // The user may have opted out while the (uncancellable) download ran —
            // a mic feature must never re-enable itself against an explicit off.
            guard !Task.isCancelled, phase != .disabled else { return }
            phase = .ready
        } catch {
            guard phase != .disabled else { return }   // opted out mid-load; stay off quietly
            phase = .disabled
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            statusMessage = "Couldn’t set up voice input: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Recording (panel)

    /// Starts listening. No-op unless idle-ready.
    func beginRecording() async {
        guard phase == .ready else { return }
        guard await PermissionsService.requestMicrophone() else {
            statusMessage = "Microphone access is off — enable it for SnippAI in System Settings → Privacy & Security."
            return
        }
        // Re-check: the await above yields; state may have moved (panel closed).
        guard phase == .ready else { return }
        do {
            try recorder.start()
            statusMessage = nil
            phase = .recording
        } catch {
            statusMessage = "Couldn’t start the microphone: \(error.localizedDescription)"
        }
    }

    /// Stops listening and returns the transcript (nil when nothing usable was heard).
    func finishAndTranscribe() async -> String? {
        guard phase == .recording else { return nil }
        phase = .transcribing
        let samples = recorder.stop()
        defer { if phase == .transcribing { phase = .ready } }
        // Sub-0.3 s of audio can't contain a word — treat as an accidental tap.
        guard Double(samples.count) / MicRecorder.sampleRate > 0.3 else { return nil }
        do {
            let text = try await transcriber.transcribe(samples)
            return text.isEmpty ? nil : text
        } catch {
            statusMessage = "Transcription failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Stops listening and discards the audio (typing fallback, panel closed).
    func cancelRecording() {
        recorder.cancel()
        if phase == .recording { phase = .ready }
    }
}
