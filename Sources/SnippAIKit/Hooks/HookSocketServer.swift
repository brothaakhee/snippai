import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public enum HookSocketError: Error, LocalizedError {
    case pathTooLong(Int)
    case socketCreateFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let n): return "Hook socket path is too long (\(n) bytes; max 104)."
        case .socketCreateFailed(let e): return "Could not create hook socket (errno \(e))."
        case .bindFailed(let e): return "Could not bind hook socket (errno \(e))."
        case .listenFailed(let e): return "Could not listen on hook socket (errno \(e))."
        }
    }
}

/// Listens on a Unix-domain stream socket for hook frames pushed by the installed
/// hook script, and delivers each decoded `HookFrame` via `onFrame`.
///
/// Design constraints (from the spec): never blocks, never crashes the app on bad
/// input, and tolerates a stale socket file from a previous run. Each hook
/// invocation opens a short-lived connection, writes one newline-terminated JSON
/// line, and closes — so a connection is read to EOF, then split on `\n`.
public final class HookSocketServer: @unchecked Sendable {
    private let path: String
    private let onFrame: @Sendable (HookFrame) -> Void

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "app.snippai.hooksocket.accept")
    private let readQueue = DispatchQueue(label: "app.snippai.hooksocket.read", attributes: .concurrent)

    /// Cap a single connection's payload so a misbehaving local writer can't make us
    /// buffer unboundedly. Real frames are a few hundred bytes to low KBs.
    private static let maxConnectionBytes = 256 * 1024

    public init(socketURL: URL = HookPaths.socket, onFrame: @escaping @Sendable (HookFrame) -> Void) {
        self.path = socketURL.path
        self.onFrame = onFrame
    }

    public var isRunning: Bool { listenFD >= 0 }

    /// Binds + listens. Idempotent-ish: a stale socket file is unlinked first so a
    /// previous unclean shutdown doesn't cause EADDRINUSE.
    public func start() throws {
        guard listenFD < 0 else { return }
        try HookPaths.ensureSupportDirectory()

        // sun_path is a fixed 104-byte buffer on Darwin; refuse anything that won't fit.
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 104 else { throw HookSocketError.pathTooLong(pathBytes.count) }

        // Remove any leftover socket file from a prior run before binding.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookSocketError.socketCreateFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: raw.count)
            pathBytes.withUnsafeBytes { src in
                raw.copyMemory(from: src)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bindResult == 0 else {
            let e = errno; close(fd); throw HookSocketError.bindFailed(e)
        }

        // Owner-only access to the socket node itself (belt-and-suspenders over the 0700 dir).
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            let e = errno; close(fd); unlink(path); throw HookSocketError.listenFailed(e)
        }

        // Non-blocking accept: the DispatchSource fires only when connections are
        // pending, and acceptConnections() then drains until accept() returns
        // -1/EWOULDBLOCK — so the accept queue is never parked inside a blocking
        // accept() (which would leak the fd/thread on teardown).
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        // Capture the fd locally (not via the shared `listenFD`) so the handler never
        // races stop()'s write to that field. GCD serializes the cancel handler's
        // close(fd) after any in-flight event handler on the same queue.
        src.setEventHandler { [weak self] in self?.acceptConnections(fd: fd) }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        unlink(path)
    }

    deinit { stop() }

    private func acceptConnections(fd: Int32) {
        // Drain the backlog. The fd is non-blocking, so accept() returns
        // -1/EWOULDBLOCK once no more connections are pending, ending the loop
        // without parking the accept queue.
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 { break }
            readQueue.async { [weak self] in self?.readConnection(conn) }
        }
    }

    private func readConnection(_ conn: Int32) {
        defer { close(conn) }

        // Don't let a hung client pin a reader thread forever.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while buffer.count < Self.maxConnectionBytes {
            let n = recv(conn, &chunk, chunk.count, 0)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else {
                break   // 0 = EOF, <0 = error/timeout
            }
        }

        // One connection may carry one or more newline-delimited frames.
        for line in buffer.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let frame = HookFrame.decode(line: Data(line)) {
                onFrame(frame)
            }
        }
    }
}
