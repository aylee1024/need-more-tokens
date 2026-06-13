import Foundation
import Testing
@testable import NeedMoreTokensKit

struct RecordedHTTPRequest: Sendable {
    let url: URL?
    let method: String?
    let headers: [String: String]
    let body: Data?
    let timeout: TimeInterval
}

enum StubHTTPResult: Sendable {
    case response(HTTPResponse)
    case transportError
}

enum StubHTTPError: Error, Sendable {
    case noResponse
    case transportError
}

actor StubHTTPClient: HTTPClient {
    private var responses: [StubHTTPResult]
    private var requests: [RecordedHTTPRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses.map(StubHTTPResult.response)
    }

    init(results: [StubHTTPResult]) {
        self.responses = results
    }

    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> HTTPResponse {
        requests.append(RecordedHTTPRequest(
            url: request.url,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody,
            timeout: timeout
        ))
        guard !responses.isEmpty else { throw StubHTTPError.noResponse }
        switch responses.removeFirst() {
        case .response(let response):
            return response
        case .transportError:
            throw StubHTTPError.transportError
        }
    }

    func recordedRequests() -> [RecordedHTTPRequest] {
        requests
    }
}

extension HTTPResponse {
    static func json(_ json: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(json.utf8), headers: ["content-type": "application/json"])
    }
}

func jsonObject(from data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

@Suite("HTTPClient stub")
struct HTTPClientStubTests {
    @Test func recordsRequestsAndReturnsCannedResponse() async throws {
        let http = StubHTTPClient(responses: [.json(#"{"ok":true}"#)])
        var request = URLRequest(url: URL(string: "https://example.com/test")!)
        request.httpMethod = "POST"
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")

        let response = try await http.send(request, timeout: 12)
        let recorded = await http.recordedRequests()

        #expect(response.status == 200)
        #expect(recorded.count == 1)
        #expect(recorded[0].url?.absoluteString == "https://example.com/test")
        #expect(recorded[0].method == "POST")
        #expect(recorded[0].headers["Authorization"] == "Bearer token")
        #expect(recorded[0].timeout == 12)
    }
}
