import XCTest
@testable import TurtleSoup

// MARK: - MockURLProtocol
//
// Intercepts every request made by a URLSession configured with
// `protocolClasses = [MockURLProtocol.self]`. Tests set `requestHandler`
// (and optionally `receivedRequest`) to script the response.
//
// Caveats:
// - `requestHandler` is `static`, so tests must reset it in tearDown to
//   avoid leaking handlers between cases.
// - URLProtocol delivers request bodies via `httpBodyStream`, not
//   `httpBody`, when set through URLSession. We re-read the stream here
//   so tests can assert against `receivedRequest?.bodyData`.

final class MockURLProtocol: URLProtocol {

    struct RecordedRequest {
        let url: URL
        let method: String
        let headers: [String: String]
        let bodyData: Data
    }

    /// Closure tests install to decide what response to send back.
    /// Returns (status, headers, body).
    static var requestHandler: ((URLRequest) throws -> (Int, [String: String], Data))?

    /// Last request the protocol intercepted, for assertion in tests.
    static var lastRequest: RecordedRequest?

    static func reset() {
        requestHandler = nil
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Snapshot the request before invoking the handler.
        let bodyData: Data
        if let body = request.httpBody {
            bodyData = body
        } else if let stream = request.httpBodyStream {
            bodyData = Self.readAll(stream)
        } else {
            bodyData = Data()
        }
        Self.lastRequest = RecordedRequest(
            url: request.url ?? URL(string: "about:blank")!,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            bodyData: bodyData
        )

        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        do {
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: bufSize)
            if n > 0 { data.append(buf, count: n) }
            else { break }
        }
        return data
    }
}

// MARK: - Tests

final class PuzzleGenerationServiceTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: cfg)
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    // MARK: Happy path

    func testGenerateReturnsPuzzleOnSuccess() async throws {
        let payload = """
        {
          "puzzle": {
            "title": "沙漠收音机",
            "scenario": "考古学家在沙漠里挖出一台还在响的收音机。",
            "answer": "其实那不是收音机，是同伴用废弃零件拼装的求救信号机。",
            "hint": "声音的来源不一定是它本身",
            "difficulty": "中等"
          }
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { _ in
            (200, ["Content-Type": "application/json"], payload)
        }

        let service = makeService(token: "tok_abc")
        let puzzle = try await service.generate(idea: "沙漠里的收音机", difficulty: .medium)

        XCTAssertEqual(puzzle.title, "沙漠收音机")
        XCTAssertEqual(puzzle.difficulty, .medium)
        XCTAssertEqual(puzzle.hint, "声音的来源不一定是它本身")
        XCTAssertEqual(puzzle.author, "AI")
        XCTAssertEqual(puzzle.playCount, 0)
    }

    // MARK: Request shape

    func testGenerateHitsCorrectEndpointAndCarriesIDToken() async throws {
        MockURLProtocol.requestHandler = { _ in
            (200, [:], minimalSuccessBody())
        }

        let service = makeService(token: "tok_xyz")
        _ = try await service.generate(idea: "test", difficulty: nil)

        let rec = MockURLProtocol.lastRequest
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.method, "POST")
        XCTAssertEqual(rec?.url.absoluteString, "https://proxy.example.com/api/v1/generate-puzzle")
        XCTAssertEqual(rec?.headers["Authorization"], "Bearer tok_xyz")
        XCTAssertEqual(rec?.headers["Content-Type"], "application/json")
    }

    func testGenerateOmitsDifficultyWhenNil() async throws {
        MockURLProtocol.requestHandler = { _ in (200, [:], minimalSuccessBody()) }
        let service = makeService(token: "t")
        _ = try await service.generate(idea: "test", difficulty: nil)

        let body = try XCTUnwrap(MockURLProtocol.lastRequest?.bodyData)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(obj?["idea"] as? String, "test")
        XCTAssertNil(obj?["difficulty"], "difficulty should be omitted when caller passes nil")
    }

    func testGenerateIncludesDifficultyWhenProvided() async throws {
        MockURLProtocol.requestHandler = { _ in (200, [:], minimalSuccessBody()) }
        let service = makeService(token: "t")
        _ = try await service.generate(idea: "test", difficulty: .hard)

        let body = try XCTUnwrap(MockURLProtocol.lastRequest?.bodyData)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(obj?["difficulty"] as? String, Puzzle.Difficulty.hard.rawValue)
    }

    // MARK: Decoding edge cases

    func testGenerateMapsUnknownDifficultyToMedium() async throws {
        let payload = """
        {"puzzle": {"title":"t","scenario":"s longer than","answer":"a longer than","difficulty":"地狱级"}}
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in (200, [:], payload) }

        let service = makeService(token: "t")
        let puzzle = try await service.generate(idea: "x", difficulty: nil)
        XCTAssertEqual(puzzle.difficulty, .medium, "Unknown difficulty should fall back to .medium")
    }

    func testGenerateTreatsEmptyHintAsNil() async throws {
        let payload = """
        {"puzzle": {"title":"t","scenario":"s","answer":"a","hint":"","difficulty":"简单"}}
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in (200, [:], payload) }

        let service = makeService(token: "t")
        let puzzle = try await service.generate(idea: "x", difficulty: nil)
        XCTAssertNil(puzzle.hint)
    }

    func testGenerateThrowsOnMalformedJSON() async {
        MockURLProtocol.requestHandler = { _ in (200, [:], Data("{not json".utf8)) }
        let service = makeService(token: "t")
        do {
            _ = try await service.generate(idea: "x", difficulty: nil)
            XCTFail("Expected decode error")
        } catch {
            // Any DecodingError is acceptable here — we just need the call to fail
            // rather than silently produce a default Puzzle.
            XCTAssertTrue(error is DecodingError, "Expected DecodingError, got \(type(of: error))")
        }
    }

    // MARK: Server errors

    func testGenerateThrowsServerErrorForNon200() async {
        let body = """
        {"error":{"code":"missing_idea","message":"Field idea is required."}}
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in (400, [:], body) }

        let service = makeService(token: "t")
        do {
            _ = try await service.generate(idea: "x", difficulty: nil)
            XCTFail("Expected server error")
        } catch let err as PuzzleGenerationService.GenerationError {
            switch err {
            case .serverError(let code, let bodyText):
                XCTAssertEqual(code, 400)
                XCTAssertTrue(bodyText.contains("missing_idea"))
                XCTAssertTrue(
                    err.errorDescription?.contains("Field idea is required") ?? false,
                    "Structured error body should be unwrapped into errorDescription"
                )
            default:
                XCTFail("Wrong error case: \(err)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: ID Token provider failures

    func testGenerateSurfacesTokenProviderError() async {
        struct StubError: LocalizedError { var errorDescription: String? { "no token" } }

        let cfg = PuzzleGenerationService.Config(
            baseURL: URL(string: "https://proxy.example.com")!,
            idTokenProvider: { throw StubError() }
        )
        let service = PuzzleGenerationService(config: cfg, session: session)

        do {
            _ = try await service.generate(idea: "x", difficulty: nil)
            XCTFail("Expected token-provider error to propagate")
        } catch let err as StubError {
            XCTAssertEqual(err.errorDescription, "no token")
        } catch {
            XCTFail("Expected StubError, got \(error)")
        }

        XCTAssertNil(
            MockURLProtocol.lastRequest,
            "No HTTP request should be made when token fetch fails"
        )
    }

    // MARK: - Streaming

    func testGenerateStreamEmitsProgressThenComplete() async throws {
        let body = proxyStreamBody(
            progressEvents: [
                ("title",      "公园里的湿长椅"),
                ("difficulty", "简单"),
                ("scenario",   "李明清晨..."),
                ("answer",     "前一晚有一对情侣..."),
                ("hint",       "湿的来源"),
            ],
            completePayload: [
                "puzzle": [
                    "title":      "公园里的湿长椅",
                    "scenario":   "李明清晨...",
                    "answer":     "前一晚有一对情侣...",
                    "hint":       "湿的来源",
                    "difficulty": "简单",
                ]
            ]
        )
        MockURLProtocol.requestHandler = { _ in
            (200, ["Content-Type": "text/event-stream"], body)
        }

        var seenProgress: [String] = []
        var finalPuzzle: Puzzle? = nil

        for try await event in makeService(token: "t").generateStream(idea: "湿长椅", difficulty: .easy) {
            switch event {
            case .progress(let field, _):
                seenProgress.append(field)
            case .complete(let puzzle):
                finalPuzzle = puzzle
            }
        }

        XCTAssertEqual(seenProgress,
                       ["title", "difficulty", "scenario", "answer", "hint"],
                       "progress events should be yielded in stream order")
        XCTAssertEqual(finalPuzzle?.title,    "公园里的湿长椅")
        XCTAssertEqual(finalPuzzle?.scenario, "李明清晨...")
        XCTAssertEqual(finalPuzzle?.difficulty, .easy)
        XCTAssertEqual(finalPuzzle?.author, "AI")
    }

    func testGenerateStreamRequestShape() async throws {
        MockURLProtocol.requestHandler = { _ in
            (200, ["Content-Type": "text/event-stream"],
             proxyStreamBody(progressEvents: [], completePayload: minimalCompletePuzzlePayload()))
        }

        _ = try await consumeStream(
            makeService(token: "tok_xyz").generateStream(idea: "x", difficulty: nil)
        )

        let rec = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(rec.url.absoluteString, "https://proxy.example.com/api/v1/generate-puzzle")
        XCTAssertEqual(rec.headers["Authorization"], "Bearer tok_xyz")
        XCTAssertEqual(rec.headers["Accept"], "text/event-stream",
                       "Stream requests should advertise text/event-stream so caches don't fold them")

        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rec.bodyData) as? [String: Any]
        )
        XCTAssertEqual(obj["stream"] as? Bool, true,
                       "generateStream must set stream:true so proxy takes the SSE branch")
        XCTAssertEqual(obj["idea"] as? String, "x")
    }

    func testGenerateStreamErrorEventThrows() async {
        let body = proxyStreamError(
            progressEvents: [("title", "won't get past this")],
            code: "parse_failed",
            message: "Tool input did not parse"
        )
        MockURLProtocol.requestHandler = { _ in
            (200, ["Content-Type": "text/event-stream"], body)
        }

        do {
            for try await _ in makeService(token: "t").generateStream(idea: "x", difficulty: nil) {}
            XCTFail("Expected error event to throw")
        } catch let err as PuzzleGenerationService.GenerationError {
            // Error events are surfaced through the same serverError case
            // (code path repurposed to carry the SSE error payload as body).
            XCTAssertTrue(err.errorDescription?.contains("parse_failed") ?? false)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testGenerateStreamSurfacesNon200() async {
        MockURLProtocol.requestHandler = { _ in (401, [:], Data("denied".utf8)) }

        do {
            for try await _ in makeService(token: "t").generateStream(idea: "x", difficulty: nil) {}
            XCTFail("Expected serverError")
        } catch let err as PuzzleGenerationService.GenerationError {
            switch err {
            case .serverError(let code, let body):
                XCTAssertEqual(code, 401)
                XCTAssertTrue(body.contains("denied"))
            default:
                XCTFail("Wrong case: \(err)")
            }
        } catch {
            XCTFail("Wrong type: \(error)")
        }
    }

    func testGenerateStreamShortCircuitsOnTokenError() async {
        struct Stub: LocalizedError { var errorDescription: String? { "no auth" } }
        let cfg = PuzzleGenerationService.Config(
            baseURL: URL(string: "https://proxy.example.com")!,
            idTokenProvider: { throw Stub() }
        )
        let service = PuzzleGenerationService(config: cfg, session: session)

        do {
            for try await _ in service.generateStream(idea: "x", difficulty: nil) {}
            XCTFail("Expected token provider error")
        } catch let e as Stub {
            XCTAssertEqual(e.errorDescription, "no auth")
        } catch {
            XCTFail("Wrong type: \(error)")
        }
        XCTAssertNil(MockURLProtocol.lastRequest, "Should not hit the network when token fetch fails")
    }

    // MARK: - Helpers

    /// Drain a stream and ignore values. Used when we only care about
    /// side effects on MockURLProtocol.lastRequest.
    private func consumeStream(_ stream: AsyncThrowingStream<PuzzleGenerationService.StreamEvent, Error>) async throws -> Bool {
        for try await _ in stream {}
        return true
    }

    private func makeService(token: String) -> PuzzleGenerationService {
        let cfg = PuzzleGenerationService.Config(
            baseURL: URL(string: "https://proxy.example.com")!,
            idTokenProvider: { token }
        )
        return PuzzleGenerationService(config: cfg, session: session)
    }
}

// MARK: - File-scope helpers

private func minimalCompletePuzzlePayload() -> [String: Any] {
    [
        "puzzle": [
            "title":      "t",
            "scenario":   "s",
            "answer":     "a",
            "difficulty": "简单",
        ]
    ]
}

private func minimalSuccessBody() -> Data {
    """
    {"puzzle":{"title":"t","scenario":"s","answer":"a","difficulty":"简单"}}
    """.data(using: .utf8)!
}
