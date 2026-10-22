import Foundation

public enum SpinnerKeyError: Error, LocalizedError, Equatable {
    case missingManagementKey(ProviderKind)
    case http(operation: String, status: Int)
    case invalidResponse(String)
    case verificationFailed
    case noTargets
    case io(String)
    case keychain(OSStatus)
    case alreadyRunning

    // Messages never include response bodies or key material.
    public var errorDescription: String? {
        switch self {
        case .missingManagementKey(let provider):
            return "No \(provider.displayName) management key is stored in the Keychain."
        case .http(let operation, let status):
            return "\(operation) failed with HTTP \(status)."
        case .invalidResponse(let detail):
            return "Unexpected response: \(detail)."
        case .verificationFailed:
            return "The newly issued key did not pass verification."
        case .noTargets:
            return "No targets selected, so there is nothing to update with a new key."
        case .io(let detail):
            return detail
        case .keychain(let status):
            return "Keychain error \(status)."
        case .alreadyRunning:
            return "Another rotation is already in progress."
        }
    }
}
