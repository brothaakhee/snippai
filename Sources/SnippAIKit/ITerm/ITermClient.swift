import Foundation

public enum ITermClientError: Error, LocalizedError {
    case notConnected
    case handshakeFailed(String)
    case rpcError(String)
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to iTerm2."
        case .handshakeFailed(let why): return "iTerm2 API handshake failed: \(why)"
        case .rpcError(let why): return "iTerm2 returned an error: \(why)"
        case .disconnected: return "The iTerm2 API connection was closed."
        }
    }
}

/// A native Swift client for iTerm2's local scripting API.
///
/// Speaks the exact wire protocol the reference Python `iterm2` library uses:
/// a WebSocket to `ws://localhost:1912` with the `api.iterm2.com` subprotocol,
/// authenticated by a cookie/key obtained via AppleScript, carrying length-framed
/// protobuf `ClientOriginatedMessage` / `ServerOriginatedMessage` payloads.
///
/// No Python runtime, no external process — a first-class native transport.
public actor ITermClient {
    private let libraryVersion = "python 2.20" // iTerm2 gates on this header; match the proven lib.
    private static let rpcTimeoutNanos: UInt64 = 30 * 1_000_000_000

    private var socketPath: String {
        let appSupport = NSHomeDirectory() + "/Library/Application Support/iTerm2"
        return appSupport + "/private/socket"
    }

    private var socket: ITermWebSocket?
    private var receiveTask: Task<Void, Never>?

    private var nextID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<Iterm2_ServerOriginatedMessage, Error>] = [:]

    /// Live notification subscribers (screen updates, session lifecycle, etc.).
    private var notificationContinuations: [UUID: AsyncStream<Iterm2_Notification>.Continuation] = [:]
    public private(set) var isConnected = false

    public init() {}

    // MARK: - Lifecycle

    public func connect() async throws {
        guard !isConnected else { return }
        let creds = try ITermAuth.obtain()

        let headers: [(String, String)] = [
            ("origin", "ws://localhost/"),
            ("x-iterm2-library-version", libraryVersion),
            ("x-iterm2-disable-auth-ui", "true"),
            ("x-iterm2-cookie", creds.cookie),
            ("x-iterm2-key", creds.key),
            ("x-iterm2-advisory-name", ITermAuth.advisoryName),
            ("Sec-WebSocket-Protocol", "api.iterm2.com"),
        ]

        let ws = ITermWebSocket(socketPath: socketPath)
        do {
            try await ws.connect(headers: headers)
        } catch {
            throw ITermClientError.handshakeFailed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        self.socket = ws
        self.isConnected = true
        startReceiveLoop()

        // Probe with a cheap, side-effect-free RPC to confirm the API is responding.
        do {
            _ = try await rpc(.listSessionsRequest(Iterm2_ListSessionsRequest()))
        } catch {
            await teardown(reportingError: error)
            throw ITermClientError.handshakeFailed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    public func disconnect() async {
        await teardown(reportingError: ITermClientError.disconnected)
    }

    private func teardown(reportingError error: Error) async {
        guard isConnected || socket != nil else { return }
        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close()
        socket = nil
        let waiters = pending
        pending.removeAll()
        for (_, cont) in waiters { cont.resume(throwing: error) }
        for (_, cont) in notificationContinuations { cont.finish() }
        notificationContinuations.removeAll()
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while await self.isConnected {
                guard let socket = await self.socket else { break }
                do {
                    let data = try await socket.receive()
                    await self.handleIncoming(data)
                } catch {
                    await self.teardown(reportingError: error)
                    break
                }
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        guard let message = try? Iterm2_ServerOriginatedMessage(serializedBytes: data) else { return }
        // Notifications are unsolicited and dispatched to subscribers regardless of id.
        if case .notification(let notification)? = message.submessage {
            for (_, cont) in notificationContinuations { cont.yield(notification) }
            return
        }
        if let cont = pending.removeValue(forKey: message.id) {
            cont.resume(returning: message)
        }
    }

    // MARK: - RPC

    /// Sends a request and awaits the matching response by message id.
    @discardableResult
    public func rpc(_ submessage: Iterm2_ClientOriginatedMessage.OneOf_Submessage) async throws -> Iterm2_ServerOriginatedMessage {
        guard isConnected, let socket else { throw ITermClientError.notConnected }
        let id = nextID
        nextID += 1
        var msg = Iterm2_ClientOriginatedMessage()
        msg.id = id
        msg.submessage = submessage
        let data = try msg.serializedData()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Iterm2_ServerOriginatedMessage, Error>) in
            // Register the waiter synchronously (no await) so a fast response can't
            // race ahead of us in the receive loop.
            pending[id] = cont
            Task {
                do {
                    try await socket.send(data)
                } catch {
                    failPending(id, error: error)
                }
            }
            // Bound the wait: a connection that stays open but stops responding
            // must not wedge the caller (and the UI) forever.
            Task {
                try? await Task.sleep(nanoseconds: Self.rpcTimeoutNanos)
                failPending(id, error: ITermClientError.rpcError("request \(id) timed out"))
            }
        }
    }

    private func failPending(_ id: Int64, error: Error) {
        if let cont = pending.removeValue(forKey: id) { cont.resume(throwing: error) }
    }

    // MARK: - High-level operations

    public func listSessions() async throws -> Iterm2_ListSessionsResponse {
        let response = try await rpc(.listSessionsRequest(Iterm2_ListSessionsRequest()))
        guard case .listSessionsResponse(let body)? = response.submessage else {
            throw ITermClientError.rpcError(response.error.isEmpty ? "no list_sessions_response" : response.error)
        }
        return body
    }

    /// Sends literal text to a session. Pass a trailing `\n` to submit.
    public func sendText(sessionID: String, text: String, suppressBroadcast: Bool = true) async throws {
        var req = Iterm2_SendTextRequest()
        req.session = sessionID
        req.text = text
        req.suppressBroadcast = suppressBroadcast
        let response = try await rpc(.sendTextRequest(req))
        guard case .sendTextResponse(let body)? = response.submessage else {
            throw ITermClientError.rpcError(response.error.isEmpty ? "no send_text_response" : response.error)
        }
        if body.status != .ok {
            throw ITermClientError.rpcError("send_text status: \(body.status)")
        }
    }

    /// Fetches the currently visible screen contents of a session.
    public func screenContents(sessionID: String) async throws -> Iterm2_GetBufferResponse {
        var range = Iterm2_LineRange()
        range.screenContentsOnly = true
        var req = Iterm2_GetBufferRequest()
        req.session = sessionID
        req.lineRange = range
        req.includeStyles = true
        let response = try await rpc(.getBufferRequest(req))
        guard case .getBufferResponse(let body)? = response.submessage else {
            throw ITermClientError.rpcError(response.error.isEmpty ? "no get_buffer_response" : response.error)
        }
        if body.status != .ok {
            throw ITermClientError.rpcError("get_buffer status: \(body.status)")
        }
        return body
    }

    /// Reads variables (e.g. "path", "autoName", "jobName") for a session.
    public func variables(sessionID: String, names: [String]) async throws -> [String: String] {
        var req = Iterm2_VariableRequest()
        req.sessionID = sessionID
        req.get = names
        let response = try await rpc(.variableRequest(req))
        guard case .variableResponse(let body)? = response.submessage else {
            throw ITermClientError.rpcError(response.error.isEmpty ? "no variable_response" : response.error)
        }
        // values are JSON-encoded, in the same order as `names`.
        var out: [String: String] = [:]
        for (name, json) in zip(names, body.values) {
            out[name] = Self.decodeVariableJSON(json)
        }
        return out
    }

    static func decodeVariableJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8) else { return json }
        if let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let s = decoded as? String { return s }
            if let n = decoded as? NSNumber { return n.stringValue }
        }
        return json.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Creates a new window (a tab with no `window_id`) and returns its session id.
    public func createWindow() async throws -> (sessionID: String, windowID: String) {
        let response = try await rpc(.createTabRequest(Iterm2_CreateTabRequest()))
        guard case .createTabResponse(let body)? = response.submessage, body.status == .ok else {
            throw ITermClientError.rpcError(response.error.isEmpty ? "create_tab failed" : response.error)
        }
        return (body.sessionID, body.windowID)
    }

    /// Closes a window by id.
    public func closeWindow(windowID: String, force: Bool = true) async throws {
        var windows = Iterm2_CloseRequest.CloseWindows()
        windows.windowIds = [windowID]
        var req = Iterm2_CloseRequest()
        req.windows = windows
        req.force = force
        _ = try await rpc(.closeRequest(req))
    }

    /// Brings a session to the foreground — selecting its tab/session, ordering its
    /// window front, and raising iTerm itself. Without `activateApp`, iTerm only
    /// reorders windows internally and never comes forward over the active app.
    public func activate(sessionID: String) async throws {
        var req = Iterm2_ActivateRequest()
        req.sessionID = sessionID
        req.orderWindowFront = true
        req.selectTab = true
        req.selectSession = true
        var app = Iterm2_ActivateRequest.App()
        app.raiseAllWindows = true
        app.ignoringOtherApps = true
        req.activateApp = app
        _ = try await rpc(.activateRequest(req))
    }

    /// Subscribes to a notification type (optionally scoped to a session).
    public func subscribe(_ type: Iterm2_NotificationType, sessionID: String? = nil) async throws {
        var req = Iterm2_NotificationRequest()
        req.subscribe = true
        req.notificationType = type
        req.session = sessionID ?? "all"
        let response = try await rpc(.notificationRequest(req))
        if case .notificationResponse(let body)? = response.submessage,
           body.status != .ok && body.status != .alreadySubscribed {
            throw ITermClientError.rpcError("subscribe status: \(body.status)")
        }
    }

    /// A live stream of server notifications (screen updates, lifecycle, etc.).
    public func notifications() -> AsyncStream<Iterm2_Notification> {
        AsyncStream { continuation in
            // Don't register a stream that nothing will ever feed or finish.
            guard isConnected else { continuation.finish(); return }
            let id = UUID()
            notificationContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeNotificationContinuation(id) }
            }
        }
    }

    private func removeNotificationContinuation(_ id: UUID) {
        notificationContinuations[id] = nil
    }
}
