import Foundation

/// Builds the real providers and targets. To add a provider or tool, add a case here.
public enum Wiring {
    #if canImport(Security)
    public static func makeRotator(store: Store = Store(), secrets: SecretStore = KeychainStore(),
                                   logger: Logger = .shared) -> Rotator {
        Rotator(store: store,
                providerFactory: { try makeProvider($0, secrets: secrets) },
                targetFactory: makeTarget,
                logger: logger)
    }
    #endif

    public static func makeProvider(_ kind: ProviderKind, secrets: SecretStore) throws -> KeyProvider {
        guard let key = try secrets.read(account: kind.managementKeyAccount), !key.isEmpty else {
            throw SpinnerKeyError.missingManagementKey(kind)
        }
        switch kind {
        case .openRouter: return OpenRouterProvider(managementKey: key)
        }
    }

    public static func makeTarget(_ kind: TargetKind) -> KeyTarget {
        switch kind {
        case .openCode: return OpenCodeTarget()
        }
    }
}

public enum Notifier {
    /// Posts a macOS notification. The message is passed as an argument, never spliced into the script.
    public static func notify(_ message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "display notification (item 1 of argv) with title \"SpinnerKey\"",
            "-e", "end run",
            message,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
