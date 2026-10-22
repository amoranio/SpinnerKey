import Foundation

/// Writes the key into OpenCode's credential store (the same file `opencode auth login` writes),
/// leaving every other provider's entry untouched.
public struct OpenCodeTarget: KeyTarget {
    public let authFile: URL

    public init(authFile: URL = OpenCodeTarget.defaultAuthFile()) {
        self.authFile = authFile
    }

    public static func defaultAuthFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode/auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    /// OpenCode's id for each provider.
    static func providerID(_ provider: ProviderKind) -> String {
        switch provider {
        case .openRouter: return "openrouter"
        }
    }

    public func install(secret: String, for provider: ProviderKind) throws -> TargetSnapshot {
        var previous: Data?
        if FileManager.default.fileExists(atPath: authFile.path) {
            previous = try Data(contentsOf: authFile)
        }

        var root: [String: Any] = [:]
        if let previous, !previous.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: previous)) as? [String: Any] else {
                throw SpinnerKeyError.io("\(authFile.path) is not valid JSON; leaving it untouched.")
            }
            root = object
        }
        root[Self.providerID(provider)] = ["type": "api", "key": secret]

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try SecureFile.atomicWrite(data, to: authFile)

        guard currentSecret(for: provider) == secret else {
            throw SpinnerKeyError.io("Wrote \(authFile.path) but could not read the new key back.")
        }
        return TargetSnapshot(previousContents: previous)
    }

    public func restore(_ snapshot: TargetSnapshot) throws {
        if let previous = snapshot.previousContents {
            try SecureFile.atomicWrite(previous, to: authFile)
        } else {
            try? FileManager.default.removeItem(at: authFile)
        }
    }

    func currentSecret(for provider: ProviderKind) -> String? {
        guard let data = try? Data(contentsOf: authFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = root[Self.providerID(provider)] as? [String: Any] else { return nil }
        return entry["key"] as? String
    }
}
