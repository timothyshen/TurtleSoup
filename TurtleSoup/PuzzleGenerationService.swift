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

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let msg): return "无效响应：\(msg)"
            case .serverError(let code, let body):
                if let parsed = try? JSONDecoder().decode(ServerErrorBody.self, from: Data(body.utf8)) {
                    return "服务器错误 (\(code))：\(parsed.error.message)"
                }
                return "服务器错误 (\(code))：\(body.prefix(200))"
            }
        }
    }

    private struct ServerErrorBody: Decodable {
        struct E: Decodable { let code: String; let message: String }
        let error: E
    }
}
