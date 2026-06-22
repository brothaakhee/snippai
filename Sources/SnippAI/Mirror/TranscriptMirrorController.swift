import Foundation
import SnippAIKit

/// Drives a `ConversationStore` from a transcript file via `TranscriptTailer`.
/// Owns the tailer lifecycle and binds to one transcript at a time; rebinding
/// (session switch) resets the store and replays the new file.
@MainActor
final class TranscriptMirrorController {
    private let store: ConversationStore
    private var tailer: TranscriptTailer?
    private(set) var currentPath: String?
    /// Bumped on every (re)bind/stop. An event that hopped to the main actor before a
    /// rebind carries the old generation and is dropped — so a fast session switch (or
    /// the cold-start→exact upgrade) can't bleed the previous session's turns into the
    /// new conversation. Same guard `AppModel` uses for its screen stream.
    private var generation = 0

    init(store: ConversationStore) {
        self.store = store
    }

    /// Mirror the transcript at `path`. No-op if already mirroring it.
    func bind(toPath path: String) {
        guard path != currentPath else { return }
        stop()                       // also bumps `generation`, invalidating in-flight events
        currentPath = path
        let gen = generation
        store.reset()
        let store = self.store
        let tailer = TranscriptTailer(path: path) { [weak self] event in
            // Hop from the tailer's background queue onto the main actor (the same
            // pattern HookController uses for socket frames), dropping any event from
            // a superseded binding.
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                store.ingest(event)
            }
        }
        self.tailer = tailer
        tailer.start()
    }

    func stop() {
        tailer?.stop()
        tailer = nil
        currentPath = nil
        generation &+= 1
    }
}
