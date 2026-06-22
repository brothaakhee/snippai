import XCTest
import Foundation
@testable import SnippAIKit

final class TranscriptTailerTests: XCTestCase {

    /// Thread-safe sink for events arriving on the tailer's background queue.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [TranscriptEvent] = []
        var onAppend: (@Sendable (Int) -> Void)?
        func add(_ e: TranscriptEvent) {
            lock.lock(); events.append(e); let n = events.count; lock.unlock()
            onAppend?(n)
        }
        var ids: [String] { lock.lock(); defer { lock.unlock() }; return events.map(\.id) }
    }

    private func tempFile(_ contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippai-tail-\(UUID().uuidString).jsonl")
        try contents.data(using: .utf8)!.write(to: url)
        return url.path
    }

    private func line(_ uuid: String, _ text: String) -> String {
        #"{"type":"user","uuid":"\#(uuid)","timestamp":"t","message":{"role":"user","content":"\#(text)"}}"# + "\n"
    }

    func testReplaysExistingLines() throws {
        let path = try tempFile(line("a", "one") + line("b", "two"))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let sink = Sink()
        let got = expectation(description: "two replayed events")
        sink.onAppend = { if $0 >= 2 { got.fulfill() } }

        let tailer = TranscriptTailer(path: path, replayExisting: true) { sink.add($0) }
        tailer.start()
        wait(for: [got], timeout: 3)
        tailer.stop()
        XCTAssertEqual(sink.ids, ["a", "b"])
    }

    func testEmitsAppendedLinesLive() throws {
        let path = try tempFile(line("a", "one"))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let sink = Sink()
        let replayed = expectation(description: "replayed first line")
        sink.onAppend = { if $0 >= 1 { replayed.fulfill() } }

        let tailer = TranscriptTailer(path: path, replayExisting: true) { sink.add($0) }
        tailer.start()
        wait(for: [replayed], timeout: 3)

        // Append a new line; the vnode watch should deliver it.
        let appended = expectation(description: "appended line observed")
        sink.onAppend = { if $0 >= 2 { appended.fulfill() } }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(line("c", "three").utf8))
        try handle.close()

        wait(for: [appended], timeout: 5)
        tailer.stop()
        XCTAssertEqual(sink.ids, ["a", "c"])
    }

    func testLargeReplayEmitsAllLinesDespiteTinyCap() throws {
        // Regression: a small pending cap must bound only a single unterminated line,
        // never discard complete-but-un-emitted events during a large replay.
        var contents = ""
        for i in 0..<500 { contents += line(String(format: "u%04d", i), "msg \(i)") }
        let path = try tempFile(contents)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let sink = Sink()
        let done = expectation(description: "all 500 lines emitted")
        sink.onAppend = { if $0 >= 500 { done.fulfill() } }

        // Cap far smaller than the total file — would wipe the buffer under the old bug.
        let tailer = TranscriptTailer(path: path, replayExisting: true, maxPendingBytes: 256) { sink.add($0) }
        tailer.start()
        wait(for: [done], timeout: 5)
        tailer.stop()
        XCTAssertEqual(sink.ids.count, 500)
        XCTAssertEqual(sink.ids.first, "u0000")
        XCTAssertEqual(sink.ids.last, "u0499")
    }

    func testRapidCreateDestroyDoesNotDeadlock() throws {
        // Regression: deinit must not dispatch_sync onto its own queue. Dropping a
        // started tailer can run deinit *on* its queue (the start() block holds the
        // last transient strong ref); a queue.sync there traps ("BUG IN CLIENT OF
        // LIBDISPATCH"). This loop crashes under that bug and passes with the fix.
        let path = try tempFile(line("a", "one"))
        defer { try? FileManager.default.removeItem(atPath: path) }
        for _ in 0..<200 {
            autoreleasepool {
                let tailer = TranscriptTailer(path: path, replayExisting: true) { _ in }
                tailer.start()
                // tailer dropped here — deinit may run on its own serial queue
            }
        }
        let drained = expectation(description: "queues drained without crash")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { drained.fulfill() }
        wait(for: [drained], timeout: 3)
    }

    func testSeekToEndSkipsExistingWhenReplayDisabled() throws {
        let path = try tempFile(line("a", "one") + line("b", "two"))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let sink = Sink()
        let tailer = TranscriptTailer(path: path, replayExisting: false) { sink.add($0) }
        tailer.start()

        let appended = expectation(description: "only the new line arrives")
        sink.onAppend = { if $0 >= 1 { appended.fulfill() } }
        // Give start() a moment to seek to EOF before we append.
        Thread.sleep(forTimeInterval: 0.3)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(line("c", "three").utf8))
        try handle.close()

        wait(for: [appended], timeout: 5)
        tailer.stop()
        XCTAssertEqual(sink.ids, ["c"])
    }
}
