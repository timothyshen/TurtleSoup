import XCTest
@testable import TurtleSoup

// Uses the shared MockURLProtocol defined in PuzzleGenerationServiceTests.swift.
// Both test files in the same target see it.

final class ClaudeServiceTests: XCTestCase {

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

    // MARK: - Direct mode

    func testDirectModeSetsAnthropicHeaders() async throws {
        MockURLProtocol.requestHandler = { _ in (200, [:], anthropicSuccessBody(verdict: "irr", comment: "")) }

        let service = ClaudeService(transport: .direct(apiKey: "sk-test-123"), session: session)
        _ = try await service.send(userInput: "hi", history: [], puzzle: samplePuzzle())

        let rec = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(rec.method, "POST")
        XCTAssertEqual(rec.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(rec.headers["x-api-key"], "sk-test-123")
        XCTAssertEqual(rec.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(rec.headers["Content-Type"], "application/json")
        XCTAssertNil(rec.headers["Authorization"], "direct mode must not send a Bearer token")
    }

    // MARK: - Proxy mode

    func testProxyModeSetsBearerAndHitsDerivedURL() async throws {
        MockURLProtocol.requestHandler = { _ in (200, [:], anthropicSuccessBody(verdict: "yes", comment: "对")) }

        let service = ClaudeService(
            transport: .proxy(baseURL: URL(string: "https://proxy.example.com")!,
                              idTokenProvider: { "tok_xyz" }),
            session: session
        )
        _ = try await service.send(userInput: "hi", history: [], puzzle: samplePuzzle())

        let rec = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(rec.method, "POST")
        XCTAssertEqual(rec.url.absoluteString, "https://proxy.example.com/api/v1/messages")
        XCTAssertEqual(rec.headers["Authorization"], "Bearer tok_xyz")
        XCTAssertNil(rec.headers["x-api-key"], "proxy mode must not leak the local key")
        XCTAssertNil(rec.headers["anthropic-version"], "anthropic-version is injected server-side")
    }

    func testProxyTokenProviderErrorSurfaces() async {
        struct Boom: LocalizedError { var errorDescription: String? { "token denied" } }

        let service = ClaudeService(
            transport: .proxy(baseURL: URL(string: "https://proxy.example.com")!,
                              idTokenProvider: { throw Boom() }),
            session: session
        )
        do {
            _ = try await service.send(userInput: "hi", history: [], puzzle: samplePuzzle())
            XCTFail("Expected token provider error")
        } catch let e as Boom {
            XCTAssertEqual(e.errorDescription, "token denied")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        XCTAssertNil(MockURLProtocol.lastRequest, "Token failure must short-circuit before HTTP")
    }

    // MARK: - Body shape

    func testRequestBodyContainsSystemAndUserMessage() async throws {
        MockURLProtocol.requestHandler = { _ in (200, [:], anthropicSuccessBody(verdict: "irr", comment: "")) }

        let service = ClaudeService(transport: .direct(apiKey: "k"), session: session)
        _ = try await service.send(userInput: "他活着吗？", history: [], puzzle: samplePuzzle())

        let body = try XCTUnwrap(MockURLProtocol.lastRequest?.bodyData)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(obj["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(obj["output_config"] as? [String: String], ["effort": "low"])
        XCTAssertEqual(obj["thinking"] as? [String: String], ["type": "disabled"])

        // System prompt now ships as a text-block array so cache_control can attach.
        let systemBlocks = try XCTUnwrap(obj["system"] as? [[String: Any]])
        XCTAssertEqual(systemBlocks.count, 1)
        let firstBlock = try XCTUnwrap(systemBlocks.first)
        XCTAssertEqual(firstBlock["type"] as? String, "text")
        let systemText = try XCTUnwrap(firstBlock["text"] as? String)
        XCTAssertTrue(systemText.contains(samplePuzzle().answer),
                      "system prompt should embed the answer (汤底) server-side equivalent path")
        XCTAssertEqual(firstBlock["cache_control"] as? [String: String], ["type": "ephemeral"],
                       "cache_control hook should be present even though prompt is currently below the 2048-token threshold")

        let messages = try XCTUnwrap(obj["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "他活着吗？")
    }

    func testHistoryFiltersSystemAndRebuildsAssistantJSON() async throws {
        MockURLProtocol.requestHandler = { _ in (200, [:], anthropicSuccessBody(verdict: "irr", comment: "")) }

        let history: [Message] = [
            Message(role: .system, text: "开始游戏"),
            Message(role: .user, text: "他是男人吗？"),
            Message(role: .assistant, text: "是", verdict: .yes),
            Message(role: .user, text: "他还活着？"),
            Message(role: .assistant, text: "无关", verdict: .irr),
        ]

        let service = ClaudeService(transport: .direct(apiKey: "k"), session: session)
        _ = try await service.send(userInput: "他认识凶手？", history: history, puzzle: samplePuzzle())

        let body = try XCTUnwrap(MockURLProtocol.lastRequest?.bodyData)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(obj["messages"] as? [[String: Any]])

        // 4 from history (system filtered) + 1 new user = 5
        XCTAssertEqual(messages.count, 5)
        XCTAssertFalse(messages.contains { ($0["role"] as? String) == "system" },
                       "system messages must be filtered from history")

        // Assistant turns are rebuilt as JSON so the model sees structured prior verdicts
        let firstAssistant = try XCTUnwrap(messages[1]["content"] as? String)
        XCTAssertTrue(firstAssistant.contains("\"verdict\":\"yes\""))
        XCTAssertTrue(firstAssistant.contains("\"comment\":\"是\""))

        // New user turn appended last
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertEqual(messages.last?["content"] as? String, "他认识凶手？")
    }

    // MARK: - Response parsing

    func testParsesPlainJSONResponse() async throws {
        MockURLProtocol.requestHandler = { _ in (200, [:], anthropicSuccessBody(verdict: "yes", comment: "对")) }

        let service = ClaudeService(transport: .direct(apiKey: "k"), session: session)
        let resp = try await service.send(userInput: "x", history: [], puzzle: samplePuzzle())
        XCTAssertEqual(resp.verdict, "yes")
        XCTAssertEqual(resp.comment, "对")
    }

    func testStripsMarkdownFenceAroundJSON() async throws {
        // Some model outputs wrap JSON in ```json ... ``` — ClaudeService strips
        // these defensively before decoding.
        let inner = #"{"verdict":"part","comment":"接近了"}"#
        let wrapped = "```json\n\(inner)\n```"
        MockURLProtocol.requestHandler = { _ in (200, [:], anthropicEnvelope(text: wrapped)) }

        let service = ClaudeService(transport: .direct(apiKey: "k"), session: session)
        let resp = try await service.send(userInput: "x", history: [], puzzle: samplePuzzle())
        XCTAssertEqual(resp.verdict, "part")
        XCTAssertEqual(resp.comment, "接近了")
    }

    func testFallsBackToIrrOnUnparseableContent() async throws {
        // The model returned prose instead of JSON. ClaudeService is documented to
        // degrade to {verdict: "irr", comment: ""} so the UI keeps moving.
        MockURLProtocol.requestHandler = { _ in
            (200, [:], anthropicEnvelope(text: "I refuse to answer in JSON."))
        }

        let service = ClaudeService(transport: .direct(apiKey: "k"), session: session)
        let resp = try await service.send(userInput: "x", history: [], puzzle: samplePuzzle())
        XCTAssertEqual(resp.verdict, "irr")
        XCTAssertEqual(resp.comment, "")
    }

    func testThrowsEmptyResponseWhenContentArrayIsEmpty() async {
        let body = #"{"content": []}"#.data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in (200, [:], body) }

        let service = ClaudeService(transport: .direct(apiKey: "k"), session: session)
        do {
            _ = try await service.send(userInput: "x", history: [], puzzle: samplePuzzle())
            XCTFail("Expected emptyResponse error")
        } catch let err as ClaudeService.ClaudeError {
            switch err {
            case .emptyResponse: break
            default: XCTFail("Wrong case: \(err)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Error propagation

    func testThrowsAPIErrorOnNon200() async {
        let body = #"{"error":{"type":"invalid_request_error","message":"bad key"}}"#.data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in (401, [:], body) }

        let service = ClaudeService(transport: .direct(apiKey: "bad"), session: session)
        do {
            _ = try await service.send(userInput: "x", history: [], puzzle: samplePuzzle())
            XCTFail("Expected apiError")
        } catch let err as ClaudeService.ClaudeError {
            switch err {
            case .apiError(let s):
                XCTAssertTrue(s.contains("invalid_request_error"),
                              "apiError should carry upstream body for diagnostics")
            default: XCTFail("Wrong case: \(err)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}

// MARK: - Helpers

private func samplePuzzle() -> Puzzle {
    Puzzle(
        id: UUID(),
        title: "测试题",
        difficulty: .medium,
        scenario: "汤面",
        answer: "汤底关键真相",
        hint: nil,
        author: "测试",
        playCount: 0
    )
}

/// Build the outer Anthropic response envelope `{content: [{text: "..."}]}`
/// where `text` is whatever raw payload you want to roundtrip.
private func anthropicEnvelope(text: String) -> Data {
    let env: [String: Any] = ["content": [["text": text]]]
    return try! JSONSerialization.data(withJSONObject: env)
}

/// Convenience for the common case: text is the verdict+comment JSON.
private func anthropicSuccessBody(verdict: String, comment: String) -> Data {
    let inner = #"{"verdict":"\#(verdict)","comment":"\#(comment)"}"#
    return anthropicEnvelope(text: inner)
}
