import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let headers: [String: String]
    public init(status: Int, body: Data, headers: [String: String]) {
        self.status = status; self.body = body; self.headers = headers
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> HTTPResponse
}

public enum HTTPClientError: Error, Sendable { case responseTooLarge }

public struct URLSessionHTTPClient: HTTPClient {
    /// ONE process-wide session. A delegate-backed URLSession retains its delegate and
    /// keeps its threads alive until invalidated; a struct can't invalidate on deinit,
    /// so per-init sessions would leak on every settings change (each rebuilds the
    /// clients). All clients share identical config, so a single lazy static session is
    /// correct and leak-free. The RedirectGuard lives for the process, which is intended.
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    private let maxResponseBytes: Int
    private let session: URLSession

    public init(maxResponseBytes: Int = 5 * 1024 * 1024) {
        self.maxResponseBytes = maxResponseBytes
        self.session = Self.sharedSession
    }

    public func send(_ request: URLRequest, timeout: TimeInterval) async throws -> HTTPResponse {
        var request = request
        request.timeoutInterval = timeout
        let (bytes, response) = try await session.bytes(for: request)
        let httpResponse = response as? HTTPURLResponse
        if let expected = httpResponse?.expectedContentLength, expected > Int64(maxResponseBytes) {
            throw HTTPClientError.responseTooLarge
        }
        var body = Data()
        body.reserveCapacity(min(maxResponseBytes, 64 * 1024))
        for try await byte in bytes {
            body.append(byte)
            if body.count > maxResponseBytes { throw HTTPClientError.responseTooLarge }
        }
        let headers = httpResponse?.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
        } ?? [:]
        return HTTPResponse(status: httpResponse?.statusCode ?? 0, body: body, headers: headers)
    }
}

/// Strips sensitive headers when a redirect changes origin (scheme/host/port) and
/// refuses any non-HTTPS redirect — prevents a server-side or MITM 3xx from carrying
/// the bearer token to another host. Same-origin redirects keep their headers.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let sensitiveHeaders = ["Authorization", "ChatGPT-Account-Id", "anthropic-beta"]
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.rewrite(originalURL: task.originalRequest?.url, newRequest: request))
    }
    static func rewrite(originalURL: URL?, newRequest request: URLRequest) -> URLRequest? {
        guard let newURL = request.url, newURL.scheme?.lowercased() == "https" else {
            return nil
        }
        if sameOrigin(originalURL, newURL) { return request }
        var stripped = request
        for header in Self.sensitiveHeaders { stripped.setValue(nil, forHTTPHeaderField: header) }
        return stripped
    }
    private static func sameOrigin(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? defaultPort(a)) == (b.port ?? defaultPort(b))
    }
    private static func defaultPort(_ url: URL) -> Int { url.scheme?.lowercased() == "https" ? 443 : 80 }
}
