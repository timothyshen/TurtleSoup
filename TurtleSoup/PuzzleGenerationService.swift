import Foundation

/// Calls the haiguitang proxy `/api/v1/generate-puzzle` endpoint.
///
/// Lives separately from `ClaudeService` because:
/// - Different endpoint path and response shape (returns `{puzzle: {...}}`,
///   not Anthropic's `{content: [...]}`).
/// - Direct-Anthropic mode isn't supported here. The endpoint orchestrates
///   Claude's tool_use; doing that client-side would require duplicating
///   the system prompt and tool schema in the macOS app, which we explicitly
///   don't want (the prompt should evolve server-side without app updates).
actor PuzzleGenerationService {

    /// Configuration for the generation request.
    /// `baseURL` is the Vercel deployment root (no path).
    struct Config {
        let baseURL: URL
        let idTokenProvider: @Sendable () async throws -> String
    }

    private let config: Config
    private let session: URLSession

    /// - Parameters:
    ///   - config: Proxy base URL + ID Token provider.
    ///   - session: Customizable for tests (inject a `URLSession` configured
    ///     with `MockURLProtocol`). Defaults to `.shared`.
    init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Generate a puzzle from a one-line idea.
    /// - Parameters:
    ///   - idea: Free-form prompt, e.g. "一个考古学家在沙漠里挖出一台收音机"
    ///   - difficulty: Optional preferred difficulty; if nil, the model picks.
    func generate(idea: String, difficulty: Puzzle.Difficulty?) async throws -> Puzzle {
        let endpoint = config.baseURL.appendingPathComponent("api/v1/generate-puzzle")

        var body: [String: Any] = ["idea": idea]
        if let difficulty {
            body["difficulty"] = difficulty.rawValue
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let token = try await config.idTokenProvider()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",   forHTTPHeaderField: "Authorization")
        req.httpBody = bodyData

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GenerationError.invalidResponse("Not an HTTP response")
        }
        guard http.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "unknown"
            throw GenerationError.serverError(http.statusCode, errText)
        }

        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        return decoded.puzzle.toPuzzle()
    }

    // MARK: - Streaming

    enum StreamEvent {
        /// A top-level field of the puzzle finished streaming. UI uses this
        /// to flip a checkmark on a progress list.
        case progress(field: String, value: String)
        /// Final assembled puzzle, ready for the editor. Stream terminates
        /// after this fires.
        case complete(Puzzle)
    }

    /// Streaming variant of `generate`. Same shape as the non-streaming
    /// method but yields `StreamEvent`s as the proxy reports field-close
    /// events from Anthropic.
    func generateStream(idea: String, difficulty: Puzzle.Difficulty?) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.runGenerationStream(
                        idea: idea, difficulty: difficulty, continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runGenerationStream(
        idea: String,
        difficulty: Puzzle.Difficulty?,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let endpoint = config.baseURL.appendingPathComponent("api/v1/generate-puzzle")
        var body: [String: Any] = ["idea": idea, "stream": true]
        if let difficulty { body["difficulty"] = difficulty.rawValue }
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let token = try await config.idTokenProvider()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = bodyData

        // One silent retry on transient connection failures (see SessionRetry).
        let (bytes, response) = try await SessionRetry.bytesWithRetry(for: req, session: session)
        guard let http = response as? HTTPURLResponse else {
            throw GenerationError.invalidResponse("Not an HTTP response")
        }
        guard http.statusCode == 200 else {
            // Drain a bounded amount of body for diagnostics.
            var errData = Data()
            for try await byte in bytes {
                errData.append(byte)
                if errData.count > 4096 { break }
            }
            let errText = String(data: errData, encoding: .utf8) ?? "unknown"
            throw GenerationError.serverError(http.statusCode, errText)
        }

        for try await event in ProxyStreamReader.events(from: bytes) {
            switch event {
            case .progress(let field, let value):
                continuation.yield(.progress(field: field, value: value))
            case .complete(let payload):
                guard let puzzleDict = payload["puzzle"] as? [String: Any],
                      let puzzle = Self.decodePuzzleDict(puzzleDict) else {
                    throw GenerationError.invalidResponse("Missing or malformed puzzle in complete event")
                }
                continuation.yield(.complete(puzzle))
                continuation.finish()
                return
            case .error(let code, let message):
                throw GenerationError.serverError(0, "{\"error\":{\"code\":\"\(code)\",\"message\":\"\(message)\"}}")
            case .refusal(let category, let explanation):
                throw GenerationError.refused(category: category, explanation: explanation)
            }
        }
        // Stream ended without complete — best-effort failure.
        throw GenerationError.invalidResponse("Stream ended without complete event")
    }

    /// Build a `Puzzle` from the dict payload of a complete event.
    /// nonisolated so it's callable without an actor hop.
    nonisolated private static func decodePuzzleDict(_ d: [String: Any]) -> Puzzle? {
        guard
            let title    = d["title"]    as? String,
            let scenario = d["scenario"] as? String,
            let answer   = d["answer"]   as? String,
            let diffRaw  = d["difficulty"] as? String
        else { return nil }
        let diff = Puzzle.Difficulty(rawValue: diffRaw) ?? .medium
        let hint = d["hint"] as? String
        return Puzzle(
            id: UUID(),
            title: title,
            difficulty: diff,
            scenario: scenario,
            answer: answer,
            hint: hint?.isEmpty == false ? hint : nil,
            author: "AI",
            playCount: 0
        )
    }

    // MARK: - Wire types

    private struct GenerateResponse: Decodable {
        let puzzle: GeneratedPuzzle
    }

    private struct GeneratedPuzzle: Decodable {
        let title: String
        let scenario: String
        let answer: String
        let hint: String?
        let difficulty: String

        func toPuzzle() -> Puzzle {
            let diff = Puzzle.Difficulty(rawValue: difficulty) ?? .medium
            return Puzzle(
                id: UUID(),
                title: title,
                difficulty: diff,
                scenario: scenario,
                answer: answer,
                hint: hint?.isEmpty == false ? hint : nil,
                author: "AI",
                playCount: 0
            )
        }
    }

    // MARK: - Errors

    enum GenerationError: LocalizedError {
        case invalidResponse(String)
        case serverError(Int, String)
        /// Anthropic refused the request (stop_reason: "refusal"). Distinct
        /// from a server error so UI can render a non-alarming notice.
        case refused(category: String?, explanation: String?)

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let msg): return "无效响应：\(msg)"
            case .serverError(let code, let body):
                if let parsed = try? JSONDecoder().decode(ServerErrorBody.self, from: Data(body.utf8)) {
                    return "服务器错误 (\(code))：\(parsed.error.message)"
                }
                return "服务器错误 (\(code))：\(body.prefix(200))"
            case .refused(_, let explanation):
                if let explanation, !explanation.isEmpty {
                    return "AI 拒绝生成：\(explanation)"
                }
                return "AI 拒绝生成此题目（可能与输入内容相关）"
            }
        }
    }

    private struct ServerErrorBody: Decodable {
        struct E: Decodable { let code: String; let message: String }
        let error: E
    }
}
