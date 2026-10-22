import Foundation

/// A service that issues API keys. Add a case (and a `KeyProvider`) to support more.
public enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case openRouter = "openrouter"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        }
    }

    /// Keychain account holding the credential used to mint and revoke keys.
    public var managementKeyAccount: String { "\(rawValue).management-key" }
}

/// A tool that consumes API keys. Add a case (and a `KeyTarget`) to support more.
public enum TargetKind: String, Codable, CaseIterable, Identifiable {
    case openCode = "opencode"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openCode: return "OpenCode"
        }
    }
}

/// One provider's key, and the tools that should receive it after each rotation.
public struct RotationJob: Codable, Equatable, Identifiable {
    public var provider: ProviderKind
    public var enabled: Bool
    public var targets: [TargetKind]
    /// Optional spend cap (USD) set on every key issued, to bound the damage of a leak.
    public var creditLimit: Double?

    public var id: String { provider.rawValue }

    public init(provider: ProviderKind, enabled: Bool, targets: [TargetKind], creditLimit: Double? = nil) {
        self.provider = provider
        self.enabled = enabled
        self.targets = targets
        self.creditLimit = creditLimit
    }
}

public struct Config: Codable, Equatable {
    public var scheduleEnabled: Bool
    public var intervalHours: Int
    /// How long a superseded key stays valid so running sessions can finish. 0 = revoke at once.
    public var revokeGraceMinutes: Int
    public var notifyOnFailure: Bool
    public var jobs: [RotationJob]

    public init(scheduleEnabled: Bool, intervalHours: Int, revokeGraceMinutes: Int,
                notifyOnFailure: Bool, jobs: [RotationJob]) {
        self.scheduleEnabled = scheduleEnabled
        self.intervalHours = intervalHours
        self.revokeGraceMinutes = revokeGraceMinutes
        self.notifyOnFailure = notifyOnFailure
        self.jobs = jobs
    }

    public static let `default` = Config(
        scheduleEnabled: false,
        intervalHours: 24,
        revokeGraceMinutes: 30,
        notifyOnFailure: true,
        jobs: [RotationJob(provider: .openRouter, enabled: true, targets: [.openCode])])

    public struct Preset: Hashable {
        public let label: String
        public let value: Int
    }

    /// Choices for `intervalHours`.
    public static let intervalPresets: [Preset] = [
        Preset(label: "6 hours", value: 6), Preset(label: "12 hours", value: 12),
        Preset(label: "Day", value: 24), Preset(label: "3 days", value: 72),
        Preset(label: "Week", value: 168), Preset(label: "30 days", value: 720),
    ]

    /// Choices for `revokeGraceMinutes`.
    public static let gracePresets: [Preset] = [
        Preset(label: "Immediately", value: 0), Preset(label: "After 15 minutes", value: 15),
        Preset(label: "After 30 minutes", value: 30), Preset(label: "After 1 hour", value: 60),
        Preset(label: "After 4 hours", value: 240),
    ]

    public var interval: TimeInterval { TimeInterval(max(intervalHours, 1)) * 3600 }
    public var revokeGrace: TimeInterval { TimeInterval(max(revokeGraceMinutes, 0)) * 60 }

    public func job(for provider: ProviderKind) -> RotationJob? {
        jobs.first { $0.provider == provider }
    }

    // Tolerate missing fields so config files from older versions keep loading.
    private enum CodingKeys: String, CodingKey {
        case scheduleEnabled, intervalHours, revokeGraceMinutes, notifyOnFailure, jobs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        scheduleEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? d.scheduleEnabled
        intervalHours = try c.decodeIfPresent(Int.self, forKey: .intervalHours) ?? d.intervalHours
        revokeGraceMinutes = try c.decodeIfPresent(Int.self, forKey: .revokeGraceMinutes) ?? d.revokeGraceMinutes
        notifyOnFailure = try c.decodeIfPresent(Bool.self, forKey: .notifyOnFailure) ?? d.notifyOnFailure
        jobs = try c.decodeIfPresent([RotationJob].self, forKey: .jobs) ?? d.jobs
    }
}
