// @preconcurrency: AVFAudio's tap types predate Sendable annotations; the tap
// closure's thread-safety is handled explicitly (see installTap below).
@preconcurrency import AVFoundation
import Observation
import os

/// Microphone capture for voice input: taps the default input, converts to the
/// 16 kHz mono Float32 that Parakeet expects, accumulates samples, and publishes
/// a smoothed level for the recording indicator.
///
/// The audio tap fires on a realtime thread — samples accumulate under a lock and
/// only the UI-facing `level` hops to the main actor. Permission is the caller's
/// job (`PermissionsService` in the app) — this type assumes access was granted.
@MainActor
@Observable
public final class MicRecorder {
    /// Smoothed input level 0…1 for the pulse UI.
    public private(set) var level: Float = 0
    public private(set) var isRecording = false

    /// Called when the audio device changes mid-recording (AirPods connect, mic
    /// unplugged) — AVAudioEngine stops silently in that case, so without this the
    /// UI would keep saying "listening" while recording nothing. The recorder has
    /// already torn down (audio discarded) when this fires.
    public var onInterrupted: (() -> Void)?

    private let engine = AVAudioEngine()
    private let sink = OSAllocatedUnfairLock<[Float]>(initialState: [])
    private var configObserver: (any NSObjectProtocol)?

    public nonisolated static let sampleRate = 16_000.0
    /// Accumulation cap (~10 minutes ≈ 38 MB) — the panel isn't a long-form
    /// recorder; beyond this, audio is dropped rather than growing unbounded.
    nonisolated static let maxSamples = Int(sampleRate) * 600

    public init() {}

    /// Starts capturing. Throws when the input device can't start (no mic, in use).
    public func start() throws {
        guard !isRecording else { return }
        sink.withLock { $0.removeAll(keepingCapacity: true) }

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: Self.sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "MicRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No usable microphone input."])
        }

        let sink = self.sink
        let ratio = Self.sampleRate / inFormat.sampleRate
        // The tap runs on AVFAudio's realtime queue. The closure MUST be @Sendable —
        // without it, Swift isolates the closure to this @MainActor type and the
        // runtime's executor assertion SIGTRAPs on the first callback. The converter
        // is only ever touched on the tap's serial queue, hence nonisolated(unsafe).
        nonisolated(unsafe) let tapConverter = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { @Sendable [weak self] buffer, _ in
            // Convert this tap buffer; the shared converter keeps resampler continuity.
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var served = false
            var convertError: NSError?
            tapConverter.convert(to: out, error: &convertError) { _, status in
                if served { status.pointee = .noDataNow; return nil }
                served = true
                status.pointee = .haveData
                return buffer
            }
            guard convertError == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
            let chunk = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            sink.withLock { samples in
                if samples.count < Self.maxSamples { samples.append(contentsOf: chunk) }
            }

            // RMS → smoothed level on the main actor (~10 updates/s at this buffer size).
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                // Square-root curve: speech RMS is small (~0.01–0.2), and a linear
                // map leaves the meter visually dead for normal voices. sqrt lifts
                // quiet speech into the visible range while still saturating loud.
                let target = min(1, (rms * 12).squareRoot())
                self.level = self.level * 0.55 + target * 0.45
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRecording = true

        // A device change stops the engine without any error surfacing here.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.cancel()
                self.onInterrupted?()
            }
        }
    }

    /// Stops capturing and returns everything recorded (16 kHz mono).
    public func stop() -> [Float] {
        teardown()
        return sink.withLock { $0 }
    }

    /// Stops capturing and discards the audio.
    public func cancel() {
        teardown()
        sink.withLock { $0.removeAll() }
    }

    private func teardown() {
        guard isRecording else { return }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        level = 0
    }
}
