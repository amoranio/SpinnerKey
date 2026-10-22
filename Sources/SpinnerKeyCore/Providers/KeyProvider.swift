import Foundation

/// A freshly issued API key. `secret` is held in memory only long enough to hand it to the targets.
public struct IssuedKey {
    /// Provider-side identifier used to revoke the key later. Not secret.
    public let id: String
    public let secret: String

    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }
}

/// A service that can mint, check and revoke API keys.
public protocol KeyProvider {
    func createKey(name: String, creditLimit: Double?) async throws -> IssuedKey
    /// True if the key is accepted for normal API use.
    func verify(secret: String) async throws -> Bool
    /// Must succeed if the key is already gone.
    func revokeKey(id: String) async throws
}

public protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// Ephemeral session: no cache, no cookies, no credential storage, redirects refused
/// (so an Authorization header can never be forwarded to another host).
public struct URLSessionTransport: HTTPTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }()

    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.scheme == "https" else {
            throw SpinnerKeyError.invalidResponse("refusing to send a request over plain HTTP")
        }
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpinnerKeyError.invalidResponse("not an HTTP response")
        }
        return (data, http.statusCode)
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
