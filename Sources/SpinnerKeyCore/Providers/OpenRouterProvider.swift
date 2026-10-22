import Foundation

/// Uses OpenRouter's key management API. Authenticated with a *management* key,
/// which can create and delete keys but cannot call models.
public struct OpenRouterProvider: KeyProvider {
    public static let baseURL = URL(string: "https://openrouter.ai/api/v1/")!

    private let managementKey: String
    private let transport: HTTPTransport

    public init(managementKey: String, transport: HTTPTransport = URLSessionTransport()) {
        self.managementKey = managementKey
        self.transport = transport
    }

    public func createKey(name: String, creditLimit: Double?) async throws -> IssuedKey {
        var body: [String: Any] = ["name": name]
        if let creditLimit { body["limit"] = creditLimit }
        let (data, status) = try await send("POST", "keys", bearer: managementKey, body: body)
        guard (200..<300).contains(status) else {
            throw SpinnerKeyError.http(operation: "Creating an OpenRouter key", status: status)
        }
        return try Self.parseCreatedKey(data)
    }

    public func verify(secret: String) async throws -> Bool {
        let (_, status) = try await send("GET", "key", bearer: secret)
        switch status {
        case 200..<300: return true
        case 401, 403: return false
        default: throw SpinnerKeyError.http(operation: "Verifying the new OpenRouter key", status: status)
        }
    }

    public func revokeKey(id: String) async throws {
        guard Self.isValidKeyID(id) else {
            throw SpinnerKeyError.invalidResponse("malformed key id")
        }
        let (_, status) = try await send("DELETE", "keys/\(id)", bearer: managementKey)
        // 404: already deleted, which is the outcome we want.
        guard (200..<300).contains(status) || status == 404 else {
            throw SpinnerKeyError.http(operation: "Revoking an OpenRouter key", status: status)
        }
    }

    /// Confirms the management key is accepted, without changing anything.
    public func checkManagementKey() async throws {
        let (_, status) = try await send("GET", "keys", bearer: managementKey)
        guard (200..<300).contains(status) else {
            throw SpinnerKeyError.http(operation: "Checking the management key", status: status)
        }
    }

    /// The create response carries the secret once, plus the key's hash under `data`.
    /// Accepts the secret at the top level or inside `data`.
    static func parseCreatedKey(_ data: Data) throws -> IssuedKey {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SpinnerKeyError.invalidResponse("create key response was not a JSON object")
        }
        let payload = object["data"] as? [String: Any]
        let secret = (object["key"] as? String) ?? (payload?["key"] as? String)
        let hash = (payload?["hash"] as? String) ?? (object["hash"] as? String)
        guard let secret, !secret.isEmpty else {
            throw SpinnerKeyError.invalidResponse("create key response had no key")
        }
        guard let hash, isValidKeyID(hash) else {
            throw SpinnerKeyError.invalidResponse("create key response had no usable hash")
        }
        return IssuedKey(id: hash, secret: secret)
    }

    /// Key ids are interpolated into a URL path, so allow only a conservative alphabet.
    static func isValidKeyID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 256 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private func send(_ method: String, _ path: String, bearer: String,
                      body: [String: Any]? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await transport.send(request)
    }
}
