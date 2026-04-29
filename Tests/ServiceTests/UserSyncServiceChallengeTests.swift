import XCTest
@testable import Blip

final class UserSyncServiceChallengeTests: XCTestCase {
    func testRequestChallenge_concurrentCallersShareSingleNetworkRequestThenClear() async throws {
        await BDEV416MockURLProtocol.reset()
        defer { Task { await BDEV416MockURLProtocol.reset() } }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BDEV416MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = UserSyncService(urlSession: session)
        let firstChallenge = String(repeating: "a", count: 64)
        let secondChallenge = String(repeating: "b", count: 64)
        let gate = BDEV416AsyncGate()

        await BDEV416MockURLProtocol.setHandler { request in
            await gate.wait()
            let requestNumber = await BDEV416MockURLProtocol.requestCount(forPathSuffix: "/auth/challenge")
            let challenge = requestNumber == 1 ? firstChallenge : secondChallenge
            guard let body = #"{"challenge":"\#(challenge)"}"#.data(using: .utf8) else {
                return BDEV416MockURLProtocol.Response(statusCode: 500, body: Data())
            }
            XCTAssertEqual(request.url?.path, "/v1/auth/challenge")
            return BDEV416MockURLProtocol.Response(statusCode: 200, body: body)
        }

        let concurrentCallers = 8
        let releaseTask = Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            await gate.release()
        }

        let challenges = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<concurrentCallers {
                group.addTask {
                    try await service.requestChallenge()
                }
            }

            var values: [String] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }
        try await releaseTask.value

        XCTAssertEqual(challenges.count, concurrentCallers)
        XCTAssertEqual(Set(challenges), [firstChallenge])
        let countAfterConcurrentCallers = await BDEV416MockURLProtocol.requestCount(forPathSuffix: "/auth/challenge")
        XCTAssertEqual(countAfterConcurrentCallers, 1, "concurrent callers should coalesce onto one challenge request")

        let followUpChallenge = try await service.requestChallenge()
        XCTAssertEqual(followUpChallenge, secondChallenge)
        let countAfterFollowUp = await BDEV416MockURLProtocol.requestCount(forPathSuffix: "/auth/challenge")
        XCTAssertEqual(countAfterFollowUp, 2, "completed challenge task should clear so the next caller starts fresh")
    }
}

private actor BDEV416AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        released = true
        for continuation in continuations {
            continuation.resume()
        }
        continuations = []
    }
}

private actor BDEV416MockURLProtocolState {
    private var handler: (@Sendable (URLRequest) async -> BDEV416MockURLProtocol.Response)?
    private var requests: [URLRequest] = []

    func setHandler(_ handler: @escaping @Sendable (URLRequest) async -> BDEV416MockURLProtocol.Response) {
        self.handler = handler
    }

    func reset() {
        handler = nil
        requests = []
    }

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func currentHandler() -> (@Sendable (URLRequest) async -> BDEV416MockURLProtocol.Response)? {
        handler
    }

    func requestCount(forPathSuffix suffix: String) -> Int {
        requests.filter { $0.url?.path.hasSuffix(suffix) ?? false }.count
    }
}

private final class BDEV416MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data
    }

    private static let state = BDEV416MockURLProtocolState()

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) async -> Response) async {
        await state.setHandler(handler)
    }

    static func reset() async {
        await state.reset()
    }

    static func requestCount(forPathSuffix suffix: String) async -> Int {
        await state.requestCount(forPathSuffix: suffix)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = self.request
        Task {
            await Self.state.record(request)
            guard let handler = await Self.state.currentHandler() else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            let response = await handler(request)
            guard let url = request.url,
                  let httpResponse = HTTPURLResponse(
                    url: url,
                    statusCode: response.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                  ) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            self.client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: response.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
