import Foundation

public struct Paths {
    public let supportDirectory: URL
    public let logDirectory: URL

    public init(supportDirectory: URL, logDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.logDirectory = logDirectory
    }

    public static var standard: Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(
            supportDirectory: home.appendingPathComponent("Library/Application Support/SpinnerKey", isDirectory: true),
            logDirectory: home.appendingPathComponent("Library/Logs/SpinnerKey", isDirectory: true))
    }

    public var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    public var stateFile: URL { supportDirectory.appendingPathComponent("state.json") }
    public var lockFile: URL { supportDirectory.appendingPathComponent(".rotation.lock") }
    public var logFile: URL { logDirectory.appendingPathComponent("spinnerkey.log") }
}
