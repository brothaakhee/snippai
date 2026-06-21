import Foundation
import Observation
import SnippAIKit

/// The observable conversation backing the native-chat mirror. Holds the decoded
/// transcript turns for the session currently being mirrored, de-duplicated by id
/// and kept in chronological order.
///
/// Ordering is by `timestamp` rather than arrival, so it stays correct even though
/// events hop from the tailer's background queue onto the main actor (where Task
/// scheduling order isn't guaranteed). The tailer delivers in file order, so the
/// common path is a cheap append; only out-of-order arrivals binary-insert.
@MainActor
@Observable
final class ConversationStore {
    private(set) var events: [TranscriptEvent] = []
    private var seen: Set<String> = []

    /// Bumped whenever new content lands, so the chat view can decide to follow the tail.
    private(set) var revision = 0

    var isEmpty: Bool { events.isEmpty }

    /// Whether anything renders to the user (ignores pure sub-agent/sidechain noise).
    var hasVisibleContent: Bool { events.contains { !$0.isSidechain } }

    func reset() {
        events.removeAll(keepingCapacity: true)
        seen.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    func ingest(_ event: TranscriptEvent) {
        guard seen.insert(event.id).inserted else { return }
        if let last = events.last, event.timestamp < last.timestamp {
            // Out-of-order arrival: insert at the chronological position.
            let idx = events.firstIndex { $0.timestamp > event.timestamp } ?? events.count
            events.insert(event, at: idx)
        } else {
            events.append(event)
        }
        revision &+= 1
    }
}
