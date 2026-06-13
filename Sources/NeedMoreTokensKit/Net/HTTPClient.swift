import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String]) {
        self.status = status
        self.body = body
        self.headers = headers
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ request: URLRequest, timeout: TimeInterval) async throws -> HTTPResponse {
        var request = request
        request.timeoutInterval = timeout

        let (body, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let headers = httpResponse?.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            let key = String(describing: pair.key).lowercased()
            result[key] = String(describing: pair.value)
        } ?? [:]

        return HTTPResponse(status: httpResponse?.statusCode ?? 0, body: body, headers: headers)
    }
}
