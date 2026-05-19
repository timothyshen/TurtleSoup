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

    // MARK: - Streaming

    func testStreamYieldsVerdictBeforeComplete() async throws {
        // Verdict arrives in the first delta, comment in the second. Verifies
        // sendStream emits .verdictReady before .complete (the whole point of
        // verdict-early-emit) and that the final response carries the full
        // comment too.
        MockURLProtocol.requestHandler = { _ in
            (200,
             ["Content-Type": "text/event-stream"],
             anthropicSSEChunkedBody(
                firstChunk:  #"{"verdict":"yes","comment":""#,
                secondChunk: #"对了"}"#
             ))
        }

        let service = ClaudeService(transport: .direct(apiKey: "k"), session: session)
        var events: [String] = []
        var finalResponse: ClaudeAgentResponse? = nil

        let stream = service.sendStream(userInput: "x", history: [], puzzle: samplePuzzle())
        for try await event in stream {
            switch event {
            case .verdictReady(let v):
                events.append("verdict:\(v)")
            case .complete(let resp):
                events.append("complete")
                finalResponse = resp
            }
        }

        XCTAssertEqual(events, ["verdict:yes", "complete"],
                       "verdict must arrive before complete and not be re-emitted")
        XCTAssertEqual(finalResponse?.verdict, "yes")
        XCTAssertEqual(finalResponse?.comment, "对了")
    }

    func testStreamCompletesWithIrrFallbackOnGarbageJSON() async throws {
        // Model misbehaves and streams non-JSON. The streaming path mirrors
        // the non-streaming defense: degrade to verdict=irr instead of
        // failing the call.
        MockURLProtocol.requestHandler = { _ in
            (200,
             ["Content-Type": "text/event-stream"],
             anthropicSSEBody(verdict: "irr", comment: "") // sentinel — but we'll inject prose
            )
        }
        // Override to emit unstructured prose:
        MockURLProtocol.requestHandler = { _ in
            let body = """
            event: content_block_delta
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"I refuse to JSON"}}

            event: message_stop
            data: {"type":"message_stop"}


            """
            return (200, ["Content-Type": "text/event-stream"], Data(body.utf8))
        }

        let service = ClaudeService(transport: .direct(apiKey: "k"), session: session)
        var finalResponse: ClaudeAgentResponse? = nil
        for try await event in service.sendStream(userInput: "x", history: [], puzzle: samplePuzzle()) {
            if case .complete(let r) = event { finalResponse = r }
        }
        XCTAssertEqual(finalResponse?.verdict, "irr")
        XCTAssertEqual(finalResponse?.comment, "")
    }

    func testStreamThrowsAPIErrorOnNon200() async {
        MockURLProtocol.requestHandler = { _ in (401, [:], Data("denied".utf8)) }
        let service = ClaudeService(transport: .direct(apiKey: "k"), session: session)
        do {
            for try await _ in service.sendStream(userInput: "x", history: [], puzzle: samplePuzzle()) {}
            XCTFail("Expected apiError")
        } catch let err as ClaudeService.ClaudeError {
            if case .apiError(let s) = err {
                XCTAssertTrue(s.contains("denied"))
            } else {
                XCTFail("Wrong case: \(err)")
            }
        } catch {
            XCTFail("Wrong type: \(error)")
        }
    }

    func testExtractVerdictHandlesPartialBuffer() {
        // Direct test of the partial-JSON extractor used by the SSE loop.
        XCTAssertNil(ClaudeService.extractVerdict(from: ""))
        XCTAssertNil(ClaudeService.extractVerdict(from: #"{"verdict":"#))
        XCTAssertNil(ClaudeService.extractVerdict(from: #"{"verdict":"y"#),
                     "open quote without close should not match")
        XCTAssertEqual(ClaudeService.extractVerdict(from: #"{"verdict":"yes""#), "yes")
        XCTAssertEqual(ClaudeService.extractVerdict(from: #"{"verdict":"part","comment":""#), "part")
        // Tolerate whitespace around the colon.
        XCTAssertEqual(ClaudeService.extractVerdict(from: #"{"verdict" : "no"}"#), "no")
    }

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

// Helpers (samplePuzzle, anthropicEnvelope, anthropicSuccessBody) live in
// TestFixtures.swift so other suites can use them too.
