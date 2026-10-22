import Foundation

/// What a target looked like before an install, so a failed rotation can put it back.
public struct TargetSnapshot {
    public let previousContents: Data?

    public init(previousContents: Data?) {
        self.previousContents = previousContents
    }
}

/// A tool that should be switched over to each newly issued key.
public protocol KeyTarget {
    func install(secret: String, for provider: ProviderKind) throws -> TargetSnapshot
    func restore(_ snapshot: TargetSnapshot) throws
}
