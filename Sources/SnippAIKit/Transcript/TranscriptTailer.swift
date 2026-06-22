import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Tails a Claude Code transcript `.jsonl` file and delivers each decoded
/// `TranscriptEvent` via `onEvent`. This is the UI-agnostic mirror engine: the
/// foreground session of a terminal CLI *and* the Claude desktop app both write
/// the same host `~/.claude/projects/.../<uuid>.jsonl`, so one tailer serves both.
///
/// Verified properties the design relies on (Phase 0 recon):
/// - Transcripts are **appended in place** with a **stable inode**, so a vnode
///   watch fires reliably and byte-offset math is exact.
/// - The file is opened append-then-closed per event by Claude, so a read-only
///   `O_EVTONLY` fd here never contends with the writer.
///
/// All mutable state is touched only on `queue`; `onEvent` is `@Sendable` and the
/// consumer hops to the main actor. De-dupe by `TranscriptEvent.id` downstream:
/// a rotation/retarget replays from the top and may re-emit lines.
public final class TranscriptTailer: @unchecked Sendable {
    private let onEvent: @Sendable (TranscriptEvent) -> Void
    private let queue = DispatchQueue(label: "app.snippai.transcript.tail")

    private var path: String
    private var replayExisting: Bool
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var offset: off_t = 0
    private var pending = Data()

    /// Bounds a single unterminated (newline-free) line — NOT the whole buffer.
    /// Complete lines are flushed before this is checked, so a large replay never
    /// loses un-emitted events. Injectable for tests.
    private let maxPendingBytes: Int

    /// - Parameters:
    ///   - path: absolute path to the transcript `.jsonl`.
    ///   - replayExisting: emit existing lines on start (true) to backfill the mirror,
    ///     or seek to EOF and only emit new lines (false).
    ///   - maxPendingBytes: cap on a single newline-free line before it is dropped.
    public init(path: String, replayExisting: Bool = true,
                maxPendingBytes: Int = 16 * 1024 * 1024,
                onEvent: @escaping @Sendable (TranscriptEvent) -> Void) {
        self.path = path
        self.replayExisting = replayExisting
        self.maxPendingBytes = maxPendingBytes
        self.onEvent = onEvent
    }

    public func start() { queue.async { [weak self] in self?.openAndPrime() } }

    public func stop() { queue.async { [weak self] in self?.teardown() } }

    /// Point the tailer at a different transcript (e.g. the desktop foreground session
    /// changed). Replays the new file from the top so the mirror is complete.
    public func retarget(path newPath: String, replayExisting: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            self.path = newPath
            self.replayExisting = replayExisting
            self.openAndPrime()
        }
    }

    // Cancel the dispatch source directly — it's thread-safe and idempotent, and its
    // cancel handler closes the fd. Must NOT hop onto `queue` here: a queued block
    // captures `self` weakly but `self?.method()` holds a transient strong ref for the
    // call, so releasing it at the block's end can run deinit *on* `queue` — and
    // `queue.sync` onto the current queue would deadlock (the crash this replaces).
    // `pending` is freed with the instance; no other thread can reach it at dealloc.
    deinit { source?.cancel() }

    // MARK: - queue-confined internals

    private func openAndPrime() {
        teardown()

        // O_EVTONLY: receive file-system events without marking the file "in use"
        // (so it doesn't block the writer's rename/unlink semantics).
        let f = open(path, O_RDONLY | O_EVTONLY)
        guard f >= 0 else { return }   // file not there yet; caller retargets when it appears
        fd = f
        offset = 0
        pending.removeAll(keepingCapacity: true)

        if replayExisting {
            drain()
        } else {
            offset = lseek(f, 0, SEEK_END)
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: f,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        src.setEventHandler { [weak self, weak src] in
            // Read `.data` from the source that actually fired (captured weakly to
            // avoid a retain cycle), not the instance field, so event→source
            // attribution is structural rather than reliant on queue ordering.
            guard let self, let src else { return }
            let events = src.data
            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                // File was replaced/compacted under us — reopen by path and replay.
                self.openAndPrime()
            } else {
                self.drain()
            }
        }
        src.setCancelHandler { close(f) }
        source = src
        src.resume()
    }

    private func teardown() {
        source?.cancel()
        source = nil
        fd = -1
        pending.removeAll(keepingCapacity: false)
    }

    /// Read everything after `offset` to EOF, then emit any complete lines.
    private func drain() {
        guard fd >= 0 else { return }

        // Detect in-place truncation/compaction: size shrank below where we were.
        var st = stat()
        if fstat(fd, &st) == 0, st.st_size < offset {
            offset = 0
            pending.removeAll(keepingCapacity: true)
        }

        _ = lseek(fd, offset, SEEK_SET)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                pending.append(contentsOf: chunk[0..<n])
                offset += off_t(n)
                // Flush complete lines as we go, so a multi-MB replay emits
                // incrementally and never buffers the whole file at once.
                emitCompleteLines()
                // What remains is a single trailing newline-free line; only THAT
                // is capped (a pathological unterminated line), never un-emitted
                // complete events.
                if pending.count > maxPendingBytes {
                    pending.removeAll(keepingCapacity: true)
                }
            } else {
                break   // 0 = EOF, <0 = would-block/error
            }
        }
    }

    /// Split out and decode every complete (newline-terminated) line in `pending`,
    /// leaving any trailing partial line buffered for the next drain.
    private func emitCompleteLines() {
        let newline = Data([0x0A])
        while let range = pending.range(of: newline) {
            let line = pending.subdata(in: pending.startIndex..<range.lowerBound)
            pending = pending.subdata(in: range.upperBound..<pending.endIndex)
            if let event = TranscriptDecoder.decode(line: line) {
                onEvent(event)
            }
        }
    }
}
