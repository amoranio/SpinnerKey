import Foundation
@testable import SpinnerKeyCore

final class FakeProvider: KeyProvider {
    var created: [IssuedKey] = []
    var revoked: [String] = []
    var verifyResult = true
    var failCreate = false
    var failRevoke = false

    func createKey(name: String, creditLimit: Double?) async throws -> IssuedKey {
        if failCreate { throw SpinnerKeyError.http(operation: "create", status: 500) }
        let key = IssuedKey(id: "hash\(created.count + 1)", secret: "sk-or-v1-secret\(created.count + 1)")
        created.append(key)
        return key
    }

    func verify(secret: String) async throws -> Bool { verifyResult }

    func revokeKey(id: String) async throws {
        if failRevoke { throw SpinnerKeyError.http(operation: "revoke", status: 503) }
        revoked.append(id)
    }
}

final class FakeTarget: KeyTarget {
    var secret: String?
    var fail = false

    func install(secret: String, for provider: ProviderKind) throws -> TargetSnapshot {
        if fail { throw SpinnerKeyError.io("target failed") }
        let previous = self.secret.map { Data($0.utf8) }
        self.secret = secret
        return TargetSnapshot(previousContents: previous)
    }

    func restore(_ snapshot: TargetSnapshot) throws {
        secret = snapshot.previousContents.map { String(decoding: $0, as: UTF8.self) }
    }
}

final class Clock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(hours: Double) { date = date.addingTimeInterval(hours * 3600) }
}

func makeTempPaths() -> Paths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("spinnerkey-tests-\(UUID().uuidString)")
    return Paths(supportDirectory: root.appendingPathComponent("support"), logDirectory: root.appendingPathComponent("logs"))
}
