import Foundation

public enum AppleScriptError: Error, LocalizedError {
    case launchFailed(String)
    case scriptError(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return "Could not run AppleScript: \(m)"
        case .scriptError(_, let m): return m.isEmpty ? "AppleScript failed." : m
        }
    }
}

/// Runs AppleScript via the `osascript` CLI. Shelling out (rather than
/// NSAppleScript) is thread-safe and works off the main actor — important since
/// adapters run on their own actors.
public enum AppleScript {
    @discardableResult
    public static func run(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]   // read the script from stdin
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AppleScriptError.launchFailed("\(error)")
        }
        stdinPipe.fileHandleForWriting.write(Data(source.utf8))
        stdinPipe.fileHandleForWriting.closeFile()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AppleScriptError.scriptError(code: errorCode(stderr) ?? Int(process.terminationStatus),
                                               message: stderr)
        }
        return String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Extracts the trailing AppleScript error code, e.g. "… (-1743)".
    public static func errorCode(_ stderr: String) -> Int? {
        guard let open = stderr.lastIndex(of: "("), stderr.hasSuffix(")") else { return nil }
        let inside = stderr[stderr.index(after: open)..<stderr.index(before: stderr.endIndex)]
        return Int(inside)
    }

    /// Escapes a Swift string for embedding inside an AppleScript double-quoted literal.
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
