import XCTest
@testable import SpinnerKeyCore

final class OpenCodeTargetTests: XCTestCase {
    var directory: URL!
    var target: OpenCodeTarget!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-\(UUID().uuidString)")
        target = OpenCodeTarget(authFile: directory.appendingPathComponent("opencode/auth.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCreatesFileWithOwnerOnlyPermissions() throws {
        _ = try target.install(secret: "sk-or-v1-new", for: .openRouter)
        let mode = try FileManager.default.attributesOfItem(atPath: target.authFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(target.currentSecret(for: .openRouter), "sk-or-v1-new")
    }

    func testPreservesOtherProviders() throws {
        try FileManager.default.createDirectory(at: target.authFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = #"{"anthropic":{"type":"oauth","refresh":"r","access":"a","expires":1},"openrouter":{"type":"api","key":"sk-or-v1-old"}}"#
        try Data(existing.utf8).write(to: target.authFile)

        _ = try target.install(secret: "sk-or-v1-new", for: .openRouter)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: target.authFile)) as! [String: Any]
        XCTAssertEqual((root["anthropic"] as? [String: Any])?["refresh"] as? String, "r")
        XCTAssertEqual((root["openrouter"] as? [String: Any])?["key"] as? String, "sk-or-v1-new")
        XCTAssertEqual((root["openrouter"] as? [String: Any])?["type"] as? String, "api")
    }

    func testRestorePutsBackExactPreviousContents() throws {
        try FileManager.default.createDirectory(at: target.authFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = Data(#"{"openrouter":{"type":"api","key":"sk-or-v1-old"}}"#.utf8)
        try existing.write(to: target.authFile)

        let snapshot = try target.install(secret: "sk-or-v1-new", for: .openRouter)
        try target.restore(snapshot)
        XCTAssertEqual(try Data(contentsOf: target.authFile), existing)
    }

    func testRefusesToOverwriteCorruptFile() throws {
        try FileManager.default.createDirectory(at: target.authFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: target.authFile)
        XCTAssertThrowsError(try target.install(secret: "sk-or-v1-new", for: .openRouter))
        XCTAssertEqual(try String(contentsOf: target.authFile), "not json")
    }

    func testDefaultPathHonoursXDGDataHome() {
        XCTAssertEqual(OpenCodeTarget.defaultAuthFile(environment: ["XDG_DATA_HOME": "/tmp/xdg"]).path, "/tmp/xdg/opencode/auth.json")
        XCTAssertTrue(OpenCodeTarget.defaultAuthFile(environment: [:]).path.hasSuffix("/.local/share/opencode/auth.json"))
    }
}

final class OpenRouterProviderTests: XCTestCase {
    final class RecordingTransport: HTTPTransport {
        var requests: [URLRequest] = []
        var responses: [(String, Int)] = []

        func send(_ request: URLRequest) async throws -> (Data, Int) {
            requests.append(request)
            let (body, status) = responses.isEmpty ? ("{}", 200) : responses.removeFirst()
            return (Data(body.utf8), status)
        }
    }

    func testParsesKeyAtTopLevel() throws {
        let key = try OpenRouterProvider.parseCreatedKey(Data(#"{"data":{"hash":"abc123","name":"x"},"key":"sk-or-v1-zzz"}"#.utf8))
        XCTAssertEqual(key.id, "abc123")
        XCTAssertEqual(key.secret, "sk-or-v1-zzz")
    }

    func testParsesKeyInsideData() throws {
        let key = try OpenRouterProvider.parseCreatedKey(Data(#"{"data":{"hash":"abc123","key":"sk-or-v1-zzz"}}"#.utf8))
        XCTAssertEqual(key.id, "abc123")
        XCTAssertEqual(key.secret, "sk-or-v1-zzz")
    }

    func testRejectsMissingOrUnsafeHash() {
        XCTAssertThrowsError(try OpenRouterProvider.parseCreatedKey(Data(#"{"key":"sk-or-v1-zzz"}"#.utf8)))
        XCTAssertThrowsError(try OpenRouterProvider.parseCreatedKey(Data(#"{"data":{"hash":"../x"},"key":"sk-or-v1-zzz"}"#.utf8)))
    }

    func testCreateSendsManagementKeyAndLimit() async throws {
        let transport = RecordingTransport()
        transport.responses = [(#"{"data":{"hash":"h1"},"key":"sk-or-v1-new"}"#, 201)]
        let provider = OpenRouterProvider(managementKey: "sk-or-v1-mgmt", transport: transport)

        _ = try await provider.createKey(name: "SpinnerKey test", creditLimit: 5)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/keys")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-v1-mgmt")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["limit"] as? Double, 5)
    }

    func testVerifyUsesTheNewKeyNotTheManagementKey() async throws {
        let transport = RecordingTransport()
        let provider = OpenRouterProvider(managementKey: "sk-or-v1-mgmt", transport: transport)
        let ok = try await provider.verify(secret: "sk-or-v1-new")
        XCTAssertTrue(ok)
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://openrouter.ai/api/v1/key")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-v1-new")
    }

    func testRevokeTreatsNotFoundAsSuccess() async throws {
        let transport = RecordingTransport()
        transport.responses = [("{}", 404)]
        let provider = OpenRouterProvider(managementKey: "m", transport: transport)
        try await provider.revokeKey(id: "h1")
        XCTAssertEqual(transport.requests.first?.httpMethod, "DELETE")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://openrouter.ai/api/v1/keys/h1")
    }

    func testRevokeFailureThrows() async {
        let transport = RecordingTransport()
        transport.responses = [("{}", 500)]
        let provider = OpenRouterProvider(managementKey: "m", transport: transport)
        do {
            try await provider.revokeKey(id: "h1")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SpinnerKeyError, .http(operation: "Revoking an OpenRouter key", status: 500))
        }
    }
}

final class MiscTests: XCTestCase {
    func testLoggerRedactsKeys() {
        XCTAssertEqual(Logger.redact("got sk-or-v1-abcdef0123456789 back"), "got sk-[REDACTED] back")
    }

    func testConfigDecodesOlderFilesWithMissingFields() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"intervalHours": 6}"#.utf8))
        XCTAssertEqual(config.intervalHours, 6)
        XCTAssertEqual(config.jobs, Config.default.jobs)
    }

    func testLaunchAgentPlistRunsRotate() throws {
        let data = try LaunchAgent(paths: makeTempPaths()).plistData(executable: "/Applications/SpinnerKey.app/Contents/MacOS/SpinnerKey")
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(plist?["ProgramArguments"] as? [String], ["/Applications/SpinnerKey.app/Contents/MacOS/SpinnerKey", "rotate"])
        XCTAssertEqual(plist?["Label"] as? String, LaunchAgent.label)
    }
}
