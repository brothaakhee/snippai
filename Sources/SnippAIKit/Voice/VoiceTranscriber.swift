import FluidAudio
import Foundation

/// Local speech-to-text: a thin, app-shaped wrapper around FluidAudio's Parakeet
/// Unified models (Apache 2.0). Fully on-device (Neural Engine); models are
/// downloaded once from HuggingFace into Application Support and cached.
///
/// De-risked by `fluid-spike`: ~600 MB download, ~90 s one-time CoreML compile,
/// 0.4 s warm load, ~200 ms to transcribe a few seconds of speech.
public actor VoiceTranscriber {
    public enum VoiceError: Error, LocalizedError {
        case notLoaded
        public var errorDescription: String? {
            switch self {
            case .notLoaded: return "Voice models aren’t loaded yet."
            }
        }
    }

    private let manager = UnifiedAsrManager()
    private var loadTask: Task<Void, Error>?

    public init() {}

    /// Where FluidAudio caches its models (mirrors the SDK's default so the cache
    /// check agrees with what `load` will find).
    public static var defaultModelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Whether the Parakeet models are already on disk (i.e. `load` won't download).
    /// The folder name comes from the SDK's own constant — never hand-copied — so
    /// this check can't drift from where `loadModels` actually caches. The marker
    /// is at least one compiled .mlmodelc bundle inside it.
    public static func modelsCached(in directory: URL) -> Bool {
        let repo = directory.appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: repo.path) else { return false }
        return contents.contains { $0.hasSuffix(".mlmodelc") }
    }

    /// Downloads (if needed) and loads the models. `progress` reports download
    /// fraction 0…1 on an arbitrary executor — hop to the main actor before
    /// touching UI state. Concurrent callers share one in-flight load (actors are
    /// reentrant — without memoization a second call mid-download would kick off
    /// a duplicate 600 MB download into the same directory).
    public func load(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if let loadTask {
            try await loadTask.value
            return
        }
        var handler: ProgressHandler?
        if let progress {
            handler = { progress($0.fractionCompleted) }
        }
        let task = Task { try await manager.loadModels(progressHandler: handler) }
        loadTask = task
        do {
            try await task.value
        } catch {
            loadTask = nil   // allow a retry after a failed download
            throw error
        }
    }

    /// Transcribes 16 kHz mono Float32 samples. Requires `load()` to have been
    /// started; awaits it if still in flight (instant once loaded).
    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let loadTask else { throw VoiceError.notLoaded }
        try await loadTask.value
        return try await manager.transcribe(samples)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
