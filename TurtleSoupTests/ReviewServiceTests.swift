import XCTest
@testable import TurtleSoup

// Uses MockURLProtocol from PuzzleGenerationServiceTests.swift.

final class ReviewServiceTests: XCTestCase {

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

    func testGenerateReturnsStructuredReview() async throws {
        let payload = """
        {
          "review": {
            "summary": "你用 8 轮锁定了真相。",
            "key_moments": [
              { "turn": 2, "kind": "good_question",    "comment": "「他认识凶手吗」直接锁定关系" },
              { "turn": 5, "kind": "wrong_direction",  "comment": "在时间维度上花了 3 轮，可惜" },
              { "turn": 7, "kind": "breakthrough",     "comment": "想到墙体共振那一刻是转折" }
            ],
            "tip": "看到「同步」相关线索时先想物理可能性。"
          }
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { _ in
            (200, ["Content-Type": "application/json"], payload)
        }

        let review = try await makeService(token: "tok_abc").generate(
            puzzle: samplePuzzle(),
            messages: sampleMessages(),
            isWon: true,
            questionCount: 8
        )

        XCTAssertEqual(review.summary, "你用 8 轮锁定了真相。")
        XCTAssertEqual(review.keyMoments.count, 3)
        XCTAssertEqual(review.keyMoments[0].kind, .goodQuestion)
        XCTAssertEqual(review.keyMoments[1].kind, .wrongDirection)
        XCTAssertEqual(review.keyMoments[2].kind, .breakthrough)
        XCTAssertEqual(review.tip, "看到「同步」相关线索时先想物理可能性。")
    }

    // MARK: Request shape

    func testHitsCorrectEndpointAndCarriesIDToken() async throws {
        MockURLProtocol.requestHandler = { _ in (200, [:], minimalReviewBody()) }
        _ = try await makeService(token: "tok_xyz").generate(
            puzzle: samplePuzzle(),
            messages: sampleMessages(),
            isWon: false,
            questionCount: 3
        )

        let rec = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(rec.method, "POST")
        XCTAssertEqual(rec.url.absoluteString, "https://proxy.example.com/api/v1/generate-review")
        XCTAssertEqual(rec.headers["Authorization"], "Bearer tok_xyz")
        XCTAssertEqual(rec.headers["Content-Type"], "application/json")
    }

    func testBodySerializesPuzzleAndTranscript() async throws {
        MockURLProtocol.requestHandler = { _ in (200, [:], minimalReviewBody()) }
        _ = try await makeService(token: "t").generate(
            puzzle: samplePuzzle(),
            messages: sampleMessages(),
            isWon: true,
            questionCount: 4
        )

        let body = try XCTUnwrap(MockURLProtocol.lastRequest?.bodyData)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(obj["isWon"] as? Bool, true)
        XCTAssertEqual(obj["questionCount"] as? Int, 4)

        let puzzle = try XCTUnwrap(obj["puzzle"] as? [String: Any])
        XCTAssertEqual(puzzle["title"] as? String, "测试题")
        XCTAssertEqual(puzzle["answer"] as? String, "汤底关键真相")

        // System messages must NOT be serialized — they're game-UI scaffolding
        // not relevant to the AI coach.
        let transcript = try XCTUnwrap(obj["transcript"] as? [[String: Any]])
        XCTAssertEqual(transcript.count, 3, "transcript should drop the system bootstrap line")
        XCTAssertEqual(transcript[0]["role"] as? String, "user")
        XCTAssertEqual(transcript[1]["role"] as? String, "assistant")
        XCTAssertEqual(transcript[1]["verdict"] as? String, "yes")
        XCTAssertEqual(transcript[2]["role"] as? String, "user")
    }

    // MARK: Error paths

    func testThrowsServerErrorWithUnwrappedMessage() async {
        let body = #"{"error":{"code":"missing_puzzle","message":"puzzle.scenario and puzzle.answer required."}}"#
            .data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in (400, [:], body) }

        do {
            _ = try await makeService(token: "t").generate(
                puzzle: samplePuzzle(),
                messages: sampleMessages(),
                isWon: true,
                questionCount: 1
            )
            XCTFail("Expected server error")
        } catch let err as ReviewService.ReviewError {
            switch err {
            case .serverError(let code, _):
                XCTAssertEqual(code, 400)
                XCTAssertTrue(err.errorDescription?.contains("puzzle.scenario") ?? false,
                              "structured error body should be unwrapped into errorDescription")
            default:
                XCTFail("Wrong case: \(err)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testTokenProviderErrorShortCircuitsRequest() async {
        struct Stub: LocalizedError { var errorDescription: String? { "denied" } }

        let cfg = ReviewService.Config(
            baseURL: URL(string: "https://proxy.example.com")!,
            idTokenProvider: { throw Stub() }
        )
        let service = ReviewService(config: cfg, session: session)

        do {
            _ = try await service.generate(
                puzzle: samplePuzzle(),
                messages: sampleMessages(),
                isWon: false,
                questionCount: 1
            )
            XCTFail("Expected token-provider error to propagate")
        } catch let e as Stub {
            XCTAssertEqual(e.errorDescription, "denied")
        } catch {
            XCTFail("Expected Stub, got \(error)")
        }

        XCTAssertNil(MockURLProtocol.lastRequest,
                     "No HTTP request should be made when token fetch fails")
    }

    // MARK: - Streaming

    func testGenerateStreamEmitsProgressThenComplete() async throws {
        let body = proxyStreamBody(
            progressEvents: [
                ("summary", "你用 5 轮锁定了真相。"),
                ("tip",     "下次先看物理约束"),
            ],
            completePayload: [
                "review": [
                    "summary": "你用 5 轮锁定了真相。",
                    "key_moments": [
                        ["turn": 1, "kind": "good_question", "comment": "切入角度对"],
                        ["turn": 3, "kind": "breakthrough",  "comment": "想到隔音问题"],
                    ],
                    "tip": "下次先看物理约束",
                ]
            ]
        )
        MockURLProtocol.requestHandler = { _ in
            (200, ["Content-Type": "text/event-stream"], body)
        }

        var seenProgress: [String] = []
        var finalReview: GameReview? = nil

        let stream = makeService(token: "t").generateStream(
            puzzle: samplePuzzle(),
            messages: sampleMessages(),
            isWon: true,
            questionCount: 5
        )
        for try await event in stream {
            switch event {
            case .progress(let field, _):
                seenProgress.append(field)
            case .complete(let review):
                finalReview = review
            }
        }

        XCTAssertEqual(seenProgress, ["summary", "tip"],
                       "progress events for review only cover summary + tip (key_moments is an array)")
        XCTAssertEqual(finalReview?.summary, "你用 5 轮锁定了真相。")
        XCTAssertEqual(finalReview?.keyMoments.count, 2,
                       "key_moments[] arrives in complete event, not via progress")
        XCTAssertEqual(finalReview?.tip, "下次先看物理约束")
    }

    func testGenerateStreamRequestShape() async throws {
        MockURLProtocol.requestHandler = { _ in
            (200, ["Content-Type": "text/event-stream"],
             proxyStreamBody(progressEvents: [], completePayload: minimalCompleteReviewPayload()))
        }

        let stream = makeService(token: "tok_xyz").generateStream(
            puzzle: samplePuzzle(),
            messages: sampleMessages(),
            isWon: false,
            questionCount: 3
        )
        for try await _ in stream {}

        let rec = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(rec.url.absoluteString, "https://proxy.example.com/api/v1/generate-review")
        XCTAssertEqual(rec.headers["Authorization"], "Bearer tok_xyz")
        XCTAssertEqual(rec.headers["Accept"], "text/event-stream")

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: rec.bodyData) as? [String: Any])
        XCTAssertEqual(obj["stream"] as? Bool, true)
        XCTAssertEqual(obj["isWon"] as? Bool, false)
        XCTAssertEqual(obj["questionCount"] as? Int, 3)
        // system messages still filtered out of transcript on the streaming path.
        let transcript = try XCTUnwrap(obj["transcript"] as? [[String: Any]])
        XCTAssertEqual(transcript.count, 3)
    }

    func testGenerateStreamErrorEventThrows() async {
        let body = proxyStreamError(code: "parse_failed", message: "bad JSON")
        MockURLProtocol.requestHandler = { _ in
            (200, ["Content-Type": "text/event-stream"], body)
        }

        do {
            let stream = makeService(token: "t").generateStream(
                puzzle: samplePuzzle(), messages: sampleMessages(),
                isWon: true, questionCount: 1
            )
            for try await _ in stream {}
            XCTFail("Expected error event to throw")
        } catch let err as ReviewService.ReviewError {
            XCTAssertTrue(err.errorDescription?.contains("parse_failed") ?? false)
        } catch {
            XCTFail("Wrong type: \(error)")
        }
    }

    func testGenerateStreamSurfacesNon200() async {
        MockURLProtocol.requestHandler = { _ in (500, [:], Data("upstream down".utf8)) }

        do {
            let stream = makeService(token: "t").generateStream(
                puzzle: samplePuzzle(), messages: sampleMessages(),
                isWon: true, questionCount: 1
            )
            for try await _ in stream {}
            XCTFail("Expected serverError")
        } catch let err as ReviewService.ReviewError {
            switch err {
            case .serverError(let code, let body):
                XCTAssertEqual(code, 500)
                XCTAssertTrue(body.contains("upstream down"))
            default:
                XCTFail("Wrong case: \(err)")
            }
        } catch {
            XCTFail("Wrong type: \(error)")
        }
    }

    func testGenerateStreamShortCircuitsOnTokenError() async {
        struct Stub: LocalizedError { var errorDescription: String? { "denied" } }
        let cfg = ReviewService.Config(
            baseURL: URL(string: "https://proxy.example.com")!,
            idTokenProvider: { throw Stub() }
        )
        let service = ReviewService(config: cfg, session: session)

        do {
            let stream = service.generateStream(
                puzzle: samplePuzzle(), messages: sampleMessages(),
                isWon: true, questionCount: 1
            )
            for try await _ in stream {}
            XCTFail("Expected Stub")
        } catch let e as Stub {
            XCTAssertEqual(e.errorDescription, "denied")
        } catch {
            XCTFail("Wrong type: \(error)")
        }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    // MARK: - Helpers

    private func makeService(token: String) -> ReviewService {
        let cfg = ReviewService.Config(
            baseURL: URL(string: "https://proxy.example.com")!,
            idTokenProvider: { token }
        )
        return ReviewService(config: cfg, session: session)
    }
}

// MARK: - File-scope fixtures (samplePuzzle lives in TestFixtures.swift)

/// Returns: system (filtered out) + user + assistant + user.
private func sampleMessages() -> [Message] {
    [
        Message(role: .system, text: "游戏开始"),
        Message(role: .user, text: "他认识凶手吗？"),
        Message(role: .assistant, text: "是", verdict: .yes),
        Message(role: .user, text: "他是亲属吗？"),
    ]
}

private func minimalCompleteReviewPayload() -> [String: Any] {
    [
        "review": [
            "summary": "s",
            "key_moments": [
                ["turn": 1, "kind": "good_question", "comment": "c"],
                ["turn": 2, "kind": "breakthrough",  "comment": "c"],
            ],
            "tip": "t",
        ]
    ]
}

private func minimalReviewBody() -> Data {
    """
    {"review":{"summary":"x","key_moments":[{"turn":1,"kind":"good_question","comment":"c1"},{"turn":2,"kind":"breakthrough","comment":"c2"}],"tip":"t"}}
    """.data(using: .utf8)!
}
