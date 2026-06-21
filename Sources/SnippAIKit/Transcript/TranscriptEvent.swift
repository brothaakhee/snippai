import Foundation

/// One renderable content block inside a transcript turn. Claude Code's on-disk
/// JSONL schema is undocumented and version-drifts, so the decoder is deliberately
/// permissive: anything it doesn't recognise becomes `.unknown(type)` rather than
/// failing the whole line.
public enum TranscriptBlock: Equatable, Sendable {
    case text(String)
    case thinking(String)
    case toolUse(name: String, input: String)
    case toolResult(text: String, isError: Bool)
    case image
    case unknown(String)

    /// Plain text for previews/tests (tool calls and images render as short tags).
    public var plainText: String {
        switch self {
        case .text(let t): return t
        case .thinking(let t): return t
        case .toolUse(let name, _): return "[tool: \(name)]"
        case .toolResult(let t, let err): return err ? "[tool error] \(t)" : t
        case .image: return "[image]"
        case .unknown(let kind): return "[\(kind)]"
        }
    }
}

/// A single user or assistant turn from a Claude Code transcript, reduced to the
/// pieces the mirror renders. Only `user`/`assistant` lines become events — the
/// other ~10 top-level types (`mode`, `permission-mode`, `file-history-snapshot`,
/// `last-prompt`, `pr-link`, `queue-operation`, `attachment`, `system`, …) are
/// skipped by the decoder.
public struct TranscriptEvent: Equatable, Sendable, Identifiable {
    public enum Role: String, Sendable, Equatable {
        case user
        case assistant
    }

    public let id: String          // the line's `uuid` (stable; used to de-dupe on replay/rotation)
    public let role: Role
    public let blocks: [TranscriptBlock]
    public let timestamp: String   // ISO-8601 as written; lexicographic order == chronological
    public let isSidechain: Bool   // true for sub-agent / parallel-workflow turns
    public let sessionID: String?
    public let model: String?
    public let cwd: String?

    public init(id: String, role: Role, blocks: [TranscriptBlock], timestamp: String,
                isSidechain: Bool, sessionID: String?, model: String?, cwd: String?) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.isSidechain = isSidechain
        self.sessionID = sessionID
        self.model = model
        self.cwd = cwd
    }

    /// All block text joined — handy for previews and assertions.
    public var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }

    /// True when every block is a tool result — i.e. a `role:user` line that is
    /// really Claude's own tool output coming back, not something the human typed.
    /// The renderer attributes these to the assistant side.
    public var isToolResultEnvelope: Bool {
        !blocks.isEmpty && blocks.allSatisfy {
            if case .toolResult = $0 { return true }
            return false
        }
    }
}

/// Pure, allocation-light decoder for one transcript JSONL line. Uses
/// `JSONSerialization` (not `Codable`) so a renamed/missing field degrades to a
/// skipped block instead of throwing the whole line away — the property the recon
/// flagged as essential given the schema drifts across Claude Code versions.
public enum TranscriptDecoder {
    /// Decodes one newline-free JSON line. Returns nil for non-user/assistant types,
    /// malformed JSON, or turns with no renderable content.
    public static func decode(line: Data) -> TranscriptEvent? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return decode(object: obj)
    }

    public static func decode(object obj: [String: Any]) -> TranscriptEvent? {
        guard let type = obj["type"] as? String,
              let role = TranscriptEvent.Role(rawValue: type),
              let message = obj["message"] as? [String: Any] else { return nil }

        let blocks = parseContent(message["content"])
        guard !blocks.isEmpty else { return nil }

        // `uuid` is normally present; synthesise a stable-ish id from timestamp when
        // absent so de-duplication still works within a session.
        let timestamp = (obj["timestamp"] as? String) ?? ""
        // Real Claude Code always writes `uuid`; this synthesis is a defensive path.
        // Fold in total content length so two same-type/same-timestamp turns don't
        // collide and get dropped as a false replay duplicate downstream.
        let contentLength = blocks.reduce(0) { $0 + $1.plainText.count }
        let id = (obj["uuid"] as? String) ?? "\(type)-\(timestamp)-\(blocks.count)-\(contentLength)"

        return TranscriptEvent(
            id: id,
            role: role,
            blocks: blocks,
            timestamp: timestamp,
            isSidechain: (obj["isSidechain"] as? Bool) ?? false,
            sessionID: obj["sessionId"] as? String,
            model: message["model"] as? String,
            cwd: obj["cwd"] as? String
        )
    }

    // MARK: - Content parsing

    /// `message.content` is either a bare string (simple user text) or an array of
    /// typed blocks (assistant turns, tool results). Both shapes handled.
    private static func parseContent(_ content: Any?) -> [TranscriptBlock] {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(text)]
        }
        // Iterate element-by-element (not a whole-array `[[String:Any]]` cast) so a
        // single unexpected element shape degrades to a skipped block instead of
        // throwing the entire turn away — the drift-tolerance contract this decoder
        // promises. Handles dict blocks and bare-string elements (multi-part input).
        guard let array = content as? [Any] else { return [] }
        return array.compactMap { element in
            if let dict = element as? [String: Any] { return parseBlock(dict) }
            if let str = element as? String {
                return str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(str)
            }
            return nil
        }
    }

    private static func parseBlock(_ block: [String: Any]) -> TranscriptBlock? {
        switch block["type"] as? String {
        case "text":
            let t = block["text"] as? String ?? ""
            return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(t)
        case "thinking":
            let t = block["thinking"] as? String ?? ""
            return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .thinking(t)
        case "tool_use":
            let name = block["name"] as? String ?? "tool"
            return .toolUse(name: name, input: compactJSON(block["input"]))
        case "tool_result":
            return .toolResult(text: stringifyContent(block["content"]),
                               isError: (block["is_error"] as? Bool) ?? false)
        case "image":
            return .image
        case let other?:
            return .unknown(other)
        case nil:
            return nil
        }
    }

    /// Serialises a tool-use `input` object to a compact, stable string for the chip.
    static func compactJSON(_ any: Any?) -> String {
        guard let any else { return "" }
        if let s = any as? String { return s }
        if JSONSerialization.isValidJSONObject(any),
           let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: any)
    }

    /// A tool_result's `content` is a string or an array of text/image blocks.
    static func stringifyContent(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let array = any as? [Any] {
            return array.compactMap { element -> String? in
                if let str = element as? String { return str }
                guard let block = element as? [String: Any] else { return nil }
                switch block["type"] as? String {
                case "text": return block["text"] as? String
                case "image": return "[image]"
                default: return nil
                }
            }.joined(separator: "\n")
        }
        return ""
    }
}
