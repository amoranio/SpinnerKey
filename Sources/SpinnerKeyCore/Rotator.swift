import Foundation

public struct RunReport {
    public struct Failure {
        public let provider: ProviderKind
        public let message: String
    }

    public var rotated: [ProviderKind] = []
    public var revokedCount = 0
    public var failures: [Failure] = []
}

/// Runs due rotations. Order of operations per job:
///
///  1. Revoke superseded keys whose grace period has passed.
///  2. Create a new key and record its id as "revoke if we crash" before using it.
///  3. Verify the new key works.
///  4. Install it in every target, rolling all targets back if any one fails.
///  5. Mark it active and schedule the old key for revocation.
///
/// A failure at any step leaves the targets on the old, working key and the new key
/// revoked (or queued for revocation), so a failed run never breaks OpenCode or leaks a key.
public final class Rotator {
    public typealias ProviderFactory = (ProviderKind) throws -> KeyProvider
    public typealias TargetFactory = (TargetKind) -> KeyTarget

    /// After a failed attempt, scheduled runs wait this long before trying again.
    public static let retryBackoff: TimeInterval = 3600

    private let store: Store
    private let makeProvider: ProviderFactory
    private let makeTarget: TargetFactory
    private let logger: Logger
    private let now: () -> Date
    private let verifyAttempts: Int
    private let verifyDelay: TimeInterval

    public init(store: Store,
                providerFactory: @escaping ProviderFactory,
                targetFactory: @escaping TargetFactory,
                logger: Logger,
                now: @escaping () -> Date = Date.init,
                verifyAttempts: Int = 4,
                verifyDelay: TimeInterval = 3) {
        self.store = store
        self.makeProvider = providerFactory
        self.makeTarget = targetFactory
        self.logger = logger
        self.now = now
        self.verifyAttempts = max(verifyAttempts, 1)
        self.verifyDelay = verifyDelay
    }

    public static func isDue(_ job: JobState, config: Config, at date: Date) -> Bool {
        guard let last = job.lastRotatedAt else { return true }
        return date >= last.addingTimeInterval(config.interval)
    }

    public static func nextDue(_ job: JobState, config: Config) -> Date? {
        job.lastRotatedAt?.addingTimeInterval(config.interval)
    }

    /// - Parameter force: rotate now even if not due (the "Rotate now" button).
    public func run(force: Bool = false) async throws -> RunReport {
        guard let lock = try FileLock.acquire(at: store.paths.lockFile) else {
            throw SpinnerKeyError.alreadyRunning
        }
        defer { withExtendedLifetime(lock) {} }

        let config = try store.loadConfig()
        var state = try store.loadState()
        var report = RunReport()

        for job in config.jobs {
            var jobState = state.jobs[job.id] ?? JobState()
            let date = now()
            let inBackoff = jobState.lastError != nil
                && (jobState.lastAttemptAt.map { date < $0.addingTimeInterval(Self.retryBackoff) } ?? false)
            let shouldRotate = job.enabled && (force || (Self.isDue(jobState, config: config, at: date) && !inBackoff))
            let hasRevocationsDue = jobState.pendingRevocations.contains { $0.revokeAfter <= date }
            guard shouldRotate || hasRevocationsDue else { continue }

            let save: (JobState) throws -> Void = { updated in
                state.jobs[job.id] = updated
                try self.store.saveState(state)
            }

            do {
                let provider = try makeProvider(job.provider)
                report.revokedCount += await revokeDue(&jobState, provider: provider)
                try save(jobState)

                if shouldRotate {
                    try await rotate(job, &jobState, provider: provider, config: config, save: save)
                    report.rotated.append(job.provider)
                    report.revokedCount += await revokeDue(&jobState, provider: provider)
                }
            } catch {
                let message = error.localizedDescription
                logger.error("\(job.provider.displayName): \(message)")
                jobState.lastAttemptAt = date
                jobState.lastError = message
                report.failures.append(.init(provider: job.provider, message: message))
            }
            try save(jobState)
        }
        return report
    }

    private func rotate(_ job: RotationJob, _ jobState: inout JobState, provider: KeyProvider,
                        config: Config, save: (JobState) throws -> Void) async throws {
        guard !job.targets.isEmpty else { throw SpinnerKeyError.noTargets }
        let started = now()
        jobState.lastAttemptAt = started
        logger.info("\(job.provider.displayName): rotating key")

        let stamp = ISO8601DateFormatter().string(from: started)
        let issued = try await provider.createKey(name: "SpinnerKey \(stamp)", creditLimit: job.creditLimit)

        // If the process dies from here on, the next run revokes this key rather than leaking it.
        jobState.pendingRevocations.append(PendingRevocation(keyID: issued.id, revokeAfter: started, reason: "in-flight"))

        do {
            try save(jobState)
            guard try await verifyWithRetry(issued.secret, provider: provider) else {
                throw SpinnerKeyError.verificationFailed
            }
            try install(issued.secret, for: job)
        } catch {
            do {
                try await provider.revokeKey(id: issued.id)
                jobState.pendingRevocations.removeAll { $0.keyID == issued.id }
            } catch {
                logger.error("\(job.provider.displayName): could not revoke unused new key yet; will retry")
            }
            throw error
        }

        jobState.pendingRevocations.removeAll { $0.keyID == issued.id }
        if let previous = jobState.activeKeyID {
            jobState.pendingRevocations.append(PendingRevocation(
                keyID: previous, revokeAfter: started.addingTimeInterval(config.revokeGrace), reason: "superseded"))
        }
        jobState.activeKeyID = issued.id
        jobState.lastRotatedAt = started
        jobState.lastError = nil
        try save(jobState)
        logger.info("\(job.provider.displayName): rotated; updated \(job.targets.map(\.displayName).joined(separator: ", "))")
    }

    private func install(_ secret: String, for job: RotationJob) throws {
        var applied: [(KeyTarget, TargetSnapshot, TargetKind)] = []
        do {
            for kind in job.targets {
                let target = makeTarget(kind)
                applied.append((target, try target.install(secret: secret, for: job.provider), kind))
            }
        } catch {
            for (target, snapshot, kind) in applied.reversed() {
                do {
                    try target.restore(snapshot)
                } catch {
                    logger.error("\(kind.displayName): could not restore previous key: \(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    /// New keys can take a moment to become valid, so retry before giving up.
    private func verifyWithRetry(_ secret: String, provider: KeyProvider) async throws -> Bool {
        var lastError: Error?
        for attempt in 1...verifyAttempts {
            do {
                if try await provider.verify(secret: secret) { return true }
                lastError = nil
            } catch {
                lastError = error
            }
            if attempt < verifyAttempts && verifyDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(verifyDelay * 1_000_000_000))
            }
        }
        if let lastError { throw lastError }
        return false
    }

    /// Failed revocations stay queued and are retried on the next run.
    private func revokeDue(_ jobState: inout JobState, provider: KeyProvider) async -> Int {
        let date = now()
        var revoked = 0
        for pending in jobState.pendingRevocations where pending.revokeAfter <= date {
            do {
                try await provider.revokeKey(id: pending.keyID)
                jobState.pendingRevocations.removeAll { $0.keyID == pending.keyID }
                revoked += 1
                logger.info("Revoked \(pending.reason) key \(pending.keyID.prefix(8))…")
            } catch {
                logger.error("Could not revoke key \(pending.keyID.prefix(8))… (will retry): \(error.localizedDescription)")
            }
        }
        return revoked
    }
}
