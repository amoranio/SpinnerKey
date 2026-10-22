import XCTest
@testable import SpinnerKeyCore

final class RotatorTests: XCTestCase {
    var store: Store!
    var provider: FakeProvider!
    var target: FakeTarget!
    var clock: Clock!
    var rotator: Rotator!

    override func setUpWithError() throws {
        store = Store(paths: makeTempPaths())
        provider = FakeProvider()
        target = FakeTarget()
        target.secret = "sk-or-v1-original"
        clock = Clock()
        var config = Config.default
        config.revokeGraceMinutes = 0
        try store.saveConfig(config)
        rotator = Rotator(store: store,
                          providerFactory: { [unowned self] _ in self.provider },
                          targetFactory: { [unowned self] _ in self.target },
                          logger: Logger(fileURL: nil),
                          now: { [unowned self] in self.clock.date },
                          verifyAttempts: 2,
                          verifyDelay: 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: store.paths.supportDirectory.deletingLastPathComponent())
    }

    private var jobState: JobState { (try? store.loadState().jobs["openrouter"]) ?? JobState() }

    func testFirstRunRotatesAndInstallsNewKey() async throws {
        let report = try await rotator.run()
        XCTAssertEqual(report.rotated, [.openRouter])
        XCTAssertEqual(target.secret, "sk-or-v1-secret1")
        XCTAssertEqual(jobState.activeKeyID, "hash1")
        XCTAssertEqual(jobState.lastRotatedAt, clock.date)
        XCTAssertTrue(jobState.pendingRevocations.isEmpty)
        XCTAssertTrue(provider.revoked.isEmpty, "never revokes keys it did not create")
    }

    func testNotDueDoesNothing() async throws {
        _ = try await rotator.run()
        clock.advance(hours: 23)
        let report = try await rotator.run()
        XCTAssertTrue(report.rotated.isEmpty)
        XCTAssertEqual(provider.created.count, 1)
    }

    func testDueRotationRevokesPreviousKey() async throws {
        _ = try await rotator.run()
        clock.advance(hours: 24)
        let report = try await rotator.run()
        XCTAssertEqual(report.rotated, [.openRouter])
        XCTAssertEqual(target.secret, "sk-or-v1-secret2")
        XCTAssertEqual(provider.revoked, ["hash1"])
        XCTAssertEqual(jobState.activeKeyID, "hash2")
    }

    func testForceRotatesEvenWhenNotDue() async throws {
        _ = try await rotator.run()
        let report = try await rotator.run(force: true)
        XCTAssertEqual(report.rotated, [.openRouter])
        XCTAssertEqual(provider.created.count, 2)
    }

    func testGracePeriodDelaysRevocation() async throws {
        var config = try store.loadConfig()
        config.revokeGraceMinutes = 60
        try store.saveConfig(config)

        _ = try await rotator.run()
        _ = try await rotator.run(force: true)
        XCTAssertTrue(provider.revoked.isEmpty)
        XCTAssertEqual(jobState.pendingRevocations.map(\.keyID), ["hash1"])

        clock.advance(hours: 0.5)
        _ = try await rotator.run()
        XCTAssertTrue(provider.revoked.isEmpty)

        clock.advance(hours: 0.5)
        _ = try await rotator.run()
        XCTAssertEqual(provider.revoked, ["hash1"])
        XCTAssertTrue(jobState.pendingRevocations.isEmpty)
    }

    func testTargetFailureKeepsOldKeyAndRevokesNewOne() async throws {
        target.fail = true
        let report = try await rotator.run()
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(target.secret, "sk-or-v1-original")
        XCTAssertEqual(provider.revoked, ["hash1"])
        XCTAssertNil(jobState.activeKeyID)
        XCTAssertNotNil(jobState.lastError)
        XCTAssertTrue(jobState.pendingRevocations.isEmpty)
    }

    func testVerificationFailureNeverTouchesTarget() async throws {
        provider.verifyResult = false
        let report = try await rotator.run()
        XCTAssertEqual(report.failures.first?.message, SpinnerKeyError.verificationFailed.errorDescription)
        XCTAssertEqual(target.secret, "sk-or-v1-original")
        XCTAssertEqual(provider.revoked, ["hash1"])
    }

    func testUnrevokableNewKeyIsQueuedForRetry() async throws {
        target.fail = true
        provider.failRevoke = true
        _ = try await rotator.run()
        XCTAssertEqual(jobState.pendingRevocations.map(\.keyID), ["hash1"])

        provider.failRevoke = false
        target.fail = false
        clock.advance(hours: 2)
        _ = try await rotator.run()
        XCTAssertTrue(provider.revoked.contains("hash1"))
        XCTAssertEqual(jobState.activeKeyID, "hash2")
        XCTAssertTrue(jobState.pendingRevocations.isEmpty)
    }

    func testFailedRunBacksOffBeforeRetrying() async throws {
        provider.failCreate = true
        _ = try await rotator.run()
        XCTAssertNotNil(jobState.lastError)

        provider.failCreate = false
        clock.advance(hours: 0.25)
        let early = try await rotator.run()
        XCTAssertTrue(early.rotated.isEmpty)

        clock.advance(hours: 1)
        let later = try await rotator.run()
        XCTAssertEqual(later.rotated, [.openRouter])
        XCTAssertNil(jobState.lastError)
    }

    func testDisabledJobIsNotRotated() async throws {
        var config = try store.loadConfig()
        config.jobs[0].enabled = false
        try store.saveConfig(config)
        let report = try await rotator.run(force: true)
        XCTAssertTrue(report.rotated.isEmpty)
        XCTAssertTrue(provider.created.isEmpty)
    }

    func testNoTargetsIsAnError() async throws {
        var config = try store.loadConfig()
        config.jobs[0].targets = []
        try store.saveConfig(config)
        let report = try await rotator.run()
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(provider.created.isEmpty)
    }

    func testConcurrentRunIsRejected() async throws {
        let lock = try FileLock.acquire(at: store.paths.lockFile)
        XCTAssertNotNil(lock)
        do {
            _ = try await rotator.run()
            XCTFail("expected alreadyRunning")
        } catch {
            XCTAssertEqual(error as? SpinnerKeyError, .alreadyRunning)
        }
        withExtendedLifetime(lock) {}
    }

    func testStateFilesNeverContainSecrets() async throws {
        _ = try await rotator.run()
        _ = try await rotator.run(force: true)
        for file in [store.paths.stateFile, store.paths.configFile] {
            let text = try String(contentsOf: file)
            XCTAssertFalse(text.contains("sk-or-v1"), "\(file.lastPathComponent) leaked a key")
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600)
        }
    }
}
