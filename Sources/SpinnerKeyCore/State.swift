import Foundation

/// A key SpinnerKey issued that must be revoked once `revokeAfter` has passed.
/// Only identifiers are stored here; key secrets are never written to SpinnerKey's files.
public struct PendingRevocation: Codable, Equatable {
    public var keyID: String
    public var revokeAfter: Date
    public var reason: String

    public init(keyID: String, revokeAfter: Date, reason: String) {
        self.keyID = keyID
        self.revokeAfter = revokeAfter
        self.reason = reason
    }
}

public struct JobState: Codable, Equatable {
    /// Provider-side identifier (not the secret) of the key currently installed in the targets.
    public var activeKeyID: String?
    public var lastRotatedAt: Date?
    public var lastAttemptAt: Date?
    public var lastError: String?
    public var pendingRevocations: [PendingRevocation]

    public init(activeKeyID: String? = nil, lastRotatedAt: Date? = nil, lastAttemptAt: Date? = nil,
                lastError: String? = nil, pendingRevocations: [PendingRevocation] = []) {
        self.activeKeyID = activeKeyID
        self.lastRotatedAt = lastRotatedAt
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.pendingRevocations = pendingRevocations
    }
}

public struct RotationState: Codable, Equatable {
    public var jobs: [String: JobState]

    public init(jobs: [String: JobState] = [:]) {
        self.jobs = jobs
    }
}

/// Reads and writes config.json and state.json (both 0600, inside a 0700 directory).
public final class Store {
    public let paths: Paths

    public init(paths: Paths = .standard) {
        self.paths = paths
    }

    public func loadConfig() throws -> Config {
        try load(Config.self, from: paths.configFile) ?? .default
    }

    public func saveConfig(_ config: Config) throws {
        try save(config, to: paths.configFile)
    }

    /// Throws on a corrupt file rather than starting fresh, so keys awaiting revocation are never forgotten.
    public func loadState() throws -> RotationState {
        try load(RotationState.self, from: paths.stateFile) ?? RotationState()
    }

    public func saveState(_ state: RotationState) throws {
        try save(state, to: paths.stateFile)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: Data(contentsOf: url))
        } catch {
            throw SpinnerKeyError.io("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFile.atomicWrite(encoder.encode(value), to: url)
    }
}
