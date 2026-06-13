import Foundation
import Network

/// A minimal RFC 6455 WebSocket client tailored to iTerm2's local API.
///
/// iTerm2 serves its scripting API over a **Unix domain socket**
/// (`~/Library/Application Support/iTerm2/private/socket`), which the system
/// `URLSessionWebSocketTask` cannot reach. This implements the handshake and
/// binary framing directly over an `NWConnection`, giving full control of the
/// custom `x-iterm2-*` handshake headers iTerm2 requires — no third-party code.
public final class ITermWebSocket: @unchecked Sendable {
    public enum WSError: Error, LocalizedError {
        case connectionFailed(String)
        case handshakeRejected(status: Int, body: String)
        case handshakeMalformed
        case closedByServer
        case protocolError(String)

        public var errorDescription: String? {
            switch self {
            case .connectionFailed(let m): return "Could not open the iTerm2 socket: \(m)"
            case .handshakeRejected(let s, let b):
                if s == 401 { return "iTerm2 rejected the connection (401): not authorized. Approve the permission dialog." }
                if s == 406 { return "iTerm2 reported a version mismatch (406)." }
                return "iTerm2 rejected the WebSocket upgrade (HTTP \(s)): \(b)"
            case .handshakeMalformed: return "iTerm2 returned a malformed WebSocket handshake."
            case .closedByServer: return "iTerm2 closed the connection."
            case .protocolError(let m): return "WebSocket protocol error: \(m)"
            }
        }
    }

    /// Defensive cap on a single message / buffered frame. The peer is the local,
    /// authenticated iTerm2 server, but we still refuse to buffer without bound.
    private let maxMessageSize = 16 * 1024 * 1024

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.snippai.iterm.ws")
    private let lock = NSLock()
    private var incoming = Data()              // raw bytes not yet parsed into frames
    private var messageBuffer = Data()         // payload of an in-progress fragmented message
    private var pendingReceives: [CheckedContinuation<Data, Error>] = []
    private var readyMessages: [Data] = []
    private var failure: Error?
    private var closed = false
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectResolved = false

    public init(socketPath: String) {
        self.connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    // MARK: - Connect + handshake

    public func connect(headers: [(String, String)]) async throws {
        try await startConnection()
        try await performHandshake(headers: headers)
        startReadLoop()
    }

    private func startConnection() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock { connectContinuation = cont }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.resolveConnect(nil)
                case .failed(let error):
                    let wrapped = WSError.connectionFailed("\(error)")
                    self?.resolveConnect(wrapped)
                    self?.fail(wrapped)
                case .cancelled:
                    self?.resolveConnect(WSError.closedByServer)
                    self?.fail(WSError.closedByServer)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Resolves the connect continuation exactly once, thread-safely.
    private func resolveConnect(_ error: Error?) {
        lock.lock()
        guard !connectResolved, let cont = connectContinuation else { lock.unlock(); return }
        connectResolved = true
        connectContinuation = nil
        lock.unlock()
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    private func performHandshake(headers: [(String, String)]) async throws {
        let key = Self.makeWebSocketKey()
        var request = "GET / HTTP/1.1\r\n"
        request += "Host: localhost\r\n"
        request += "Upgrade: websocket\r\n"
        request += "Connection: Upgrade\r\n"
        request += "Sec-WebSocket-Version: 13\r\n"
        request += "Sec-WebSocket-Key: \(key)\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        request += "\r\n"

        try await rawSend(Data(request.utf8))

        // Read until end of HTTP headers (\r\n\r\n).
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            let chunk = try await rawReceive()
            buffer.append(chunk)
            if let range = buffer.range(of: terminator) {
                let headerData = buffer.subdata(in: buffer.startIndex..<range.upperBound)
                // Any bytes after the header terminator are the first WS frame bytes.
                let leftover = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                if !leftover.isEmpty { lock.withLock { incoming.append(leftover) } }
                try parseHandshakeResponse(headerData)
                return
            }
            if buffer.count > 64 * 1024 { throw WSError.handshakeMalformed }
        }
    }

    private func parseHandshakeResponse(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8),
              let statusLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            throw WSError.handshakeMalformed
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { throw WSError.handshakeMalformed }
        guard status == 101 else {
            throw WSError.handshakeRejected(status: status, body: String(text.prefix(200)))
        }
    }

    // MARK: - Public message API

    /// Sends one binary message (a single, unfragmented, masked frame).
    public func send(_ data: Data) async throws {
        let frame = Self.encodeFrame(opcode: 0x2, payload: data)
        try await rawSend(frame)
    }

    /// Awaits the next complete binary message, transparently handling control frames.
    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            // Drain any already-buffered message before honoring a failure, so a
            // valid final response that arrived alongside a close frame isn't lost.
            if !readyMessages.isEmpty {
                let msg = readyMessages.removeFirst()
                lock.unlock(); cont.resume(returning: msg); return
            }
            if let failure {
                lock.unlock(); cont.resume(throwing: failure); return
            }
            pendingReceives.append(cont)
            lock.unlock()
        }
    }

    public func close() {
        lock.withLock { closed = true }
        // Best-effort close frame, then cancel.
        let frame = Self.encodeFrame(opcode: 0x8, payload: Data())
        connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    // MARK: - Read loop + frame parsing

    private func startReadLoop() {
        receiveMore()
        // Process anything captured during the handshake — on `queue`, so ALL frame
        // parsing is serialized there and never races the receive callbacks.
        queue.async { [weak self] in self?.drainFrames() }
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.fail(WSError.connectionFailed("\(error)")); return }
            if let data, !data.isEmpty {
                self.lock.withLock { self.incoming.append(data) }
                self.drainFrames()
            }
            if isComplete { self.fail(WSError.closedByServer); return }
            if self.lock.withLock({ self.closed || self.failure != nil }) { return }
            self.receiveMore()
        }
    }

    /// Parses every complete frame currently buffered. Runs only on `queue`, so it
    /// never overlaps another drain. The whole parse (decode + fragment assembly +
    /// FIN) is one critical section; side effects are dispatched after the unlock.
    private func drainFrames() {
        var completed: [Data] = []
        var pongs: [Data] = []
        var protocolError: String?
        var serverClosed = false

        lock.lock()
        let bytes = [UInt8](incoming)
        var cursor = 0
        parse: while true {
            switch Self.decodeFrame(bytes, from: cursor, maxSize: maxMessageSize) {
            case .incomplete:
                break parse
            case .error(let message):
                protocolError = message
                break parse
            case .frame(let frame, let next):
                cursor = next
                switch frame.opcode {
                case 0x0, 0x1, 0x2: // continuation / text / binary
                    messageBuffer.append(frame.payload)
                    if messageBuffer.count > maxMessageSize {
                        protocolError = "message exceeds \(maxMessageSize) bytes"
                        break parse
                    }
                    if frame.fin {
                        completed.append(messageBuffer)
                        messageBuffer.removeAll(keepingCapacity: true)
                    }
                case 0x8: // close
                    serverClosed = true
                    break parse
                case 0x9: // ping -> queue a pong
                    pongs.append(Self.encodeFrame(opcode: 0xA, payload: frame.payload))
                case 0xA: // pong
                    break
                default:
                    break
                }
            }
        }
        incoming = cursor > 0 ? Data(bytes[cursor...]) : incoming
        lock.unlock()

        for pong in pongs { connection.send(content: pong, completion: .idempotent) }
        for message in completed { deliver(message) }
        if let protocolError { fail(WSError.protocolError(protocolError)) }
        else if serverClosed { fail(WSError.closedByServer) }
    }

    private func deliver(_ message: Data) {
        lock.lock()
        if !pendingReceives.isEmpty {
            let cont = pendingReceives.removeFirst()
            lock.unlock()
            cont.resume(returning: message)
        } else {
            readyMessages.append(message)
            lock.unlock()
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        if failure != nil { lock.unlock(); return }
        failure = error
        closed = true   // stop receiveMore() re-arming a read on a dead connection
        let waiters = pendingReceives
        pendingReceives.removeAll()
        lock.unlock()
        connection.cancel()
        for cont in waiters { cont.resume(throwing: error) }
    }

    // MARK: - Low-level NWConnection send/receive

    private func rawSend(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: WSError.connectionFailed("\(error)")) }
                else { cont.resume() }
            })
        }
    }

    private func rawReceive() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let error { cont.resume(throwing: WSError.connectionFailed("\(error)")); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(throwing: WSError.closedByServer); return }
                cont.resume(returning: Data())
            }
        }
    }

    // MARK: - RFC 6455 framing

    struct ParsedFrame { let fin: Bool; let opcode: UInt8; let payload: Data }

    enum DecodeResult {
        case incomplete                       // need more bytes
        case frame(ParsedFrame, next: Int)    // a frame + the cursor past it
        case error(String)                    // protocol violation -> fail the connection
    }

    static func makeWebSocketKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
    }

    /// Encodes a client frame. Clients MUST mask per RFC 6455.
    static func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0F)) // FIN + opcode
        let len = payload.count
        var mask = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { mask[i] = UInt8.random(in: 0...255) }

        if len < 126 {
            frame.append(0x80 | UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xFF))
            }
        }
        frame.append(contentsOf: mask)
        var masked = [UInt8](payload)
        for i in 0..<masked.count { masked[i] ^= mask[i % 4] }
        frame.append(contentsOf: masked)
        return frame
    }

    /// Decodes one frame starting at `start`. Cursor-based (no per-call buffer
    /// copy) and validates RFC 6455 invariants for a server->client frame.
    static func decodeFrame(_ bytes: [UInt8], from start: Int, maxSize: Int) -> DecodeResult {
        guard bytes.count - start >= 2 else { return .incomplete }
        let b0 = bytes[start], b1 = bytes[start + 1]
        let fin = (b0 & 0x80) != 0
        if (b0 & 0x70) != 0 { return .error("reserved RSV bits set") }
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        if masked { return .error("server frame must not be masked") }

        // Opcode validity: data 0x0-0x2, control 0x8-0xA; all others reserved.
        let isControl = (opcode & 0x08) != 0
        switch opcode {
        case 0x0, 0x1, 0x2, 0x8, 0x9, 0xA: break
        default: return .error("reserved opcode 0x\(String(opcode, radix: 16))")
        }

        var offset = start + 2
        var payloadLen = Int(b1 & 0x7F)
        if payloadLen == 126 {
            guard bytes.count - offset >= 2 else { return .incomplete }
            payloadLen = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
        } else if payloadLen == 127 {
            guard bytes.count - offset >= 8 else { return .incomplete }
            var len: UInt64 = 0
            for i in 0..<8 { len = (len << 8) | UInt64(bytes[offset + i]) }
            // MSB must be 0 per RFC; reject anything we won't buffer anyway.
            if len > UInt64(maxSize) { return .error("frame length \(len) exceeds max") }
            payloadLen = Int(len)
            offset += 8
        }

        // Control frames must be final and <= 125 bytes.
        if isControl && (!fin || payloadLen > 125) {
            return .error("invalid control frame (fin=\(fin) len=\(payloadLen))")
        }
        guard bytes.count - offset >= payloadLen else { return .incomplete }

        let payload = Data(bytes[offset..<offset + payloadLen])
        return .frame(ParsedFrame(fin: fin, opcode: opcode, payload: payload), next: offset + payloadLen)
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
