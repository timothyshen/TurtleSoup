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

    // MARK: - Helpers

    private func makeService(token: String) -> ReviewService {
        let cfg = ReviewService.Config(
            baseURL: URL(string: "https://proxy.example.com")!,
            idTokenProvider: { token }
        )
        return ReviewService(config: cfg, session: session)
    }
}

// MARK: - File-scope fixtures

private func samplePuzzle() -> Puzzle {
    Puzzle(id: UUID(), title: "测试题", difficulty: .medium,
           scenario: "汤面", answer: "汤底关键真相",
           hint: nil, author: "测试", playCount: 0)
}

/// Returns: system (filtered out) + user + assistant + user.
private func sampleMessages() -> [Message] {
    [
        Message(role: .system, text: "游戏开始"),
        Message(role: .user, text: "他认识凶手吗？"),
        Message(role: .assistant, text: "是", verdict: .yes),
        Message(role: .user, text: "他是亲属吗？"),
    ]
}

private func minimalReviewBody() -> Data {
    """
    {"review":{"summary":"x","key_moments":[{"turn":1,"kind":"good_question","comment":"c1"},{"turn":2,"kind":"breakthrough","comment":"c2"}],"tip":"t"}}
    """.data(using: .utf8)!
}
