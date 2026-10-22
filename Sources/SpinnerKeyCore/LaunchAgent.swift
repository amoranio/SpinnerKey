import Foundation

/// The per-user launchd job that runs `SpinnerKey rotate` every 15 minutes and at login.
/// Each run is a cheap local check; network calls happen only when a rotation or revocation is due.
/// No daemon stays resident, and nothing runs as root.
public struct LaunchAgent {
    public static let label = "com.spinnerkey.agent"
    public static let checkIntervalSeconds = 900

    public let plistURL: URL
    private let paths: Paths

    public init(paths: Paths = .standard) {
        self.paths = paths
        self.plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func plistData(executable: String) throws -> Data {
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable, "rotate"],
            "StartInterval": Self.checkIntervalSeconds,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "StandardErrorPath": paths.logDirectory.appendingPathComponent("agent-stderr.log").path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Installs (or refreshes) the agent so it runs `executable`. No-op if already current.
    public func install(executable: String) throws {
        let data = try plistData(executable: executable)
        if let existing = try? Data(contentsOf: plistURL), existing == data { return }
        try SecureFile.ensureDirectory(paths.logDirectory)
        try SecureFile.atomicWrite(data, to: plistURL)
        launchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
        let status = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard status == 0 else {
            throw SpinnerKeyError.io("launchctl could not load the scheduler (exit \(status)).")
        }
    }

    public func uninstall() throws {
        launchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
        if isInstalled {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    @discardableResult
    private func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
