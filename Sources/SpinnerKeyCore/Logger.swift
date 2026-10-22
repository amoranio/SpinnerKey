import Foundation

/// Append-only log at ~/Library/Logs/SpinnerKey/spinnerkey.log, capped at ~1 MB.
/// Anything that looks like an API key is redacted before it is written.
public final class Logger {
    public static let shared = Logger(fileURL: Paths.standard.logFile)

    private let fileURL: URL?
    private let queue = DispatchQueue(label: "spinnerkey.logger")
    private let maxBytes = 1_000_000
    private static let keyPattern = try! NSRegularExpression(pattern: "sk-[A-Za-z0-9_-]{8,}")

    /// Pass nil for a logger that only echoes to an interactive terminal.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    public func info(_ message: String) { write("INFO", message) }
    public func error(_ message: String) { write("ERROR", message) }

    static func redact(_ message: String) -> String {
        let range = NSRange(message.startIndex..., in: message)
        return keyPattern.stringByReplacingMatches(in: message, range: range, withTemplate: "sk-[REDACTED]")
    }

    private func write(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(Logger.redact(message))\n"
        if isatty(STDOUT_FILENO) != 0 {
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        guard let url = fileURL else { return }
        queue.sync {
            let fm = FileManager.default
            try? SecureFile.ensureDirectory(url.deletingLastPathComponent())
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                let previous = url.appendingPathExtension("1")
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: url, to: previous)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
