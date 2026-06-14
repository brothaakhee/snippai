import Foundation

public enum AdapterRouterError: Error, LocalizedError {
    case noneAvailable
    case unknownSession

    public var errorDescription: String? {
        switch self {
        case .noneAvailable: return "No supported terminal is running. Open iTerm2 or Terminal.app."
        case .unknownSession: return "That session is no longer available — refresh."
        }
    }
}

/// Fans discovery across several `TargetAdapter`s (iTerm2, Terminal.app, …) and
/// routes send/stream/focus back to whichever adapter owns each session — the
/// "target picker + per-target adapters" model. Connects to whatever is running
/// and only fails if *nothing* is available.
public actor AdapterRouter: TargetAdapter {
    public nonisolated let displayName = "Terminals"
    private let adapters: [any TargetAdapter]
    private var connectedIndices: [Int] = []
    private var routing: [String: Int] = [:]   // session id -> adapter index

    public init(adapters: [any TargetAdapter]) {
        self.adapters = adapters
    }

    public func connect() async throws {
        var connected: [Int] = []
        var firstError: Error?
        for (index, adapter) in adapters.enumerated() {
            do {
                try await adapter.connect()
                connected.append(index)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        connectedIndices = connected
        if connected.isEmpty {
            // With multiple adapters, no single adapter's error represents the whole
            // ("iTerm2 not running" is misleading when Terminal is also down) — use
            // the aggregate. With one adapter, its specific error is the useful one.
            throw adapters.count > 1 ? AdapterRouterError.noneAvailable : (firstError ?? AdapterRouterError.noneAvailable)
        }
    }

    public func disconnect() async {
        for index in connectedIndices { await adapters[index].disconnect() }
        connectedIndices = []
        routing.removeAll()
    }

    public func discover() async throws -> [TerminalSession] {
        let adapters = self.adapters
        let indices = connectedIndices
        let perAdapter: [(Int, [TerminalSession])] = await withTaskGroup(of: (Int, [TerminalSession]).self) { group in
            for index in indices {
                group.addTask { (index, (try? await adapters[index].discover()) ?? []) }
            }
            var acc: [(Int, [TerminalSession])] = []
            for await result in group { acc.append(result) }
            return acc
        }

        // Rebuild routing and merge in a stable adapter order.
        routing.removeAll()
        var merged: [TerminalSession] = []
        for (index, sessions) in perAdapter.sorted(by: { $0.0 < $1.0 }) {
            for session in sessions {
                routing[session.id] = index
                merged.append(session)
            }
        }
        return merged
    }

    public func send(text: String, toSession sessionID: String) async throws {
        try await adapter(for: sessionID).send(text: text, toSession: sessionID)
    }

    public func snapshot(ofSession sessionID: String) async throws -> TerminalScreen {
        try await adapter(for: sessionID).snapshot(ofSession: sessionID)
    }

    public func screenStream(forSession sessionID: String) async throws -> AsyncStream<TerminalScreen> {
        try await adapter(for: sessionID).screenStream(forSession: sessionID)
    }

    public func focus(sessionID: String) async throws {
        try await adapter(for: sessionID).focus(sessionID: sessionID)
    }

    private func adapter(for sessionID: String) throws -> any TargetAdapter {
        guard let index = routing[sessionID] else { throw AdapterRouterError.unknownSession }
        return adapters[index]
    }
}
