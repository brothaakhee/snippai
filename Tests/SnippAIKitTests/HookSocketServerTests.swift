import XCTest
import Foundation
@testable import SnippAIKit

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Exercises the real AF_UNIX listener with a real client connection — the
/// C-interop path that unit tests of the pure types can't cover.
final class HookSocketServerTests: XCTestCase {
    private var socketURL: URL!
    private var server: HookSocketServer!

    override func setUpWithError() throws {
        socketURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snippai-sock-\(UUID().uuidString.prefix(8)).sock")
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    /// Sends raw bytes to a Unix-domain stream socket and closes (mimics the hook's
    /// `nc -U` one-shot delivery).
    private func sendToSocket(_ path: String, _ bytes: [UInt8]) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes.prefix(raw.count - 1))
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        XCTAssertEqual(rc, 0, "client connect failed (errno \(errno))")
        var buf = bytes
        _ = write(fd, &buf, buf.count)
    }

    func testReceivesAndDecodesOneFrame() throws {
        let received = Expectation<HookFrame>()
        let exp = expectation(description: "frame received")
        server = HookSocketServer(socketURL: socketURL) { frame in
            received.set(frame); exp.fulfill()
        }
        try server.start()

        let json = #"{"v":1,"event":"Stop","iterm":"w0t5p0:GUID-1","tty":"/dev/ttys003"}"# + "\n"
        try sendToSocket(socketURL.path, Array(json.utf8))

        wait(for: [exp], timeout: 3)
        XCTAssertEqual(received.value?.event, "Stop")
        XCTAssertEqual(received.value?.itermSessionGUID, "GUID-1")
        XCTAssertEqual(received.value?.tty, "/dev/ttys003")
    }

    func testMultipleFramesInOneConnection() throws {
        let count = Counter()
        let exp = expectation(description: "two frames")
        exp.expectedFulfillmentCount = 2
        server = HookSocketServer(socketURL: socketURL) { _ in
            count.increment(); exp.fulfill()
        }
        try server.start()

        let two = #"{"v":1,"event":"Stop","iterm":"a:1"}"# + "\n" + #"{"v":1,"event":"Notification","iterm":"a:2"}"# + "\n"
        try sendToSocket(socketURL.path, Array(two.utf8))

        wait(for: [exp], timeout: 3)
        XCTAssertEqual(count.value, 2)
    }

    func testMalformedLineIsDroppedNotCrashing() throws {
        let exp = expectation(description: "only the good frame arrives")
        server = HookSocketServer(socketURL: socketURL) { frame in
            XCTAssertEqual(frame.event, "Stop"); exp.fulfill()
        }
        try server.start()

        // First line is junk, second is valid. The junk must not take down the listener.
        let mixed = "{ not json\n" + #"{"v":1,"event":"Stop","iterm":"a:1"}"# + "\n"
        try sendToSocket(socketURL.path, Array(mixed.utf8))

        wait(for: [exp], timeout: 3)
    }

    func testStopThenRestartDeliversAgain() throws {
        // Proves teardown is clean (the non-blocking accept loop doesn't park a
        // thread on the fd): we can stop and rebind on the same path and still
        // receive frames.
        let exp = expectation(description: "frame after restart")
        server = HookSocketServer(socketURL: socketURL) { _ in }
        try server.start()
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path),
                       "stop() should unlink the socket file")

        server = HookSocketServer(socketURL: socketURL) { frame in
            XCTAssertEqual(frame.event, "Stop"); exp.fulfill()
        }
        try server.start()
        try sendToSocket(socketURL.path, Array((#"{"v":1,"event":"Stop","iterm":"a:1"}"# + "\n").utf8))
        wait(for: [exp], timeout: 3)
    }

    func testStaleSocketFileIsReplacedOnStart() throws {
        // Leave a stale file where the socket should bind.
        FileManager.default.createFile(atPath: socketURL.path, contents: Data("stale".utf8))
        server = HookSocketServer(socketURL: socketURL) { _ in }
        XCTAssertNoThrow(try server.start(), "start should unlink a stale socket file and bind cleanly")
    }
}

/// Minimal thread-safe boxes for assertions across the socket's background queue.
private final class Expectation<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ v: T) { lock.lock(); stored = v; lock.unlock() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func increment() { lock.lock(); n += 1; lock.unlock() }
}
