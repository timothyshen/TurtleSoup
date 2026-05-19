import Foundation

/// Structured post-game review from the AI coach.
///
/// Stored on `GameRecord` as a JSON-encoded string so we don't have to migrate
/// CoreData every time we add a field. Renderable directly from this struct.
struct GameReview: Codable, Equatable {
    let summary: String
    let keyMoments: [Moment]
    let tip: String

    struct Moment: Codable, Equatable, Identifiable {
        /// Player's question number (1-indexed). Used to anchor the comment
        /// to a specific turn in the transcript.
        let turn: Int
        let kind: Kind
        let comment: String

        var id: String { "\(turn)-\(kind.rawValue)" }

        enum Kind: String, Codable {
            case goodQuestion    = "good_question"
            case wrongDirection  = "wrong_direction"
            case breakthrough    = "breakthrough"
            case gotStuck        = "got_stuck"

            /// Short Chinese label for UI badges.
            var label: String {
                switch self {
                case .goodQuestion:   return "好问题"
                case .wrongDirection: return "走偏了"
                case .breakthrough:   return "关键突破"
                case .gotStuck:       return "卡住了"
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case turn, kind, comment
        }
    }

    enum CodingKeys: String, CodingKey {
        case summary
        case keyMoments = "key_moments"
        case tip
    }
}

/// Calls the haiguitang proxy `/api/v1/generate-review` endpoint.
///
/// Like `PuzzleGenerationService`, this is proxy-only by design — the prompt,
/// tool schema, and review rubric live server-side so we can iterate without
/// app updates.
actor ReviewService {

    struct Config {
        let baseURL: URL
        let idTokenProvider: @Sendable () async throws -> String
    }

    private let config: Config
    private let session: URLSession

    init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Generate a post-game review.
    /// - Parameters:
    ///   - puzzle: The puzzle that was played. The full answer (汤底) is sent
    ///     to the proxy so the AI can judge whether the player was on track.
    ///   - messages: All user/assistant turns in chronological order.
    ///     System messages should be filtered out by the caller.
    ///   - isWon: True if the player solved the puzzle; false if they gave up.
    ///   - questionCount: Total number of user turns.
    func generate(
        puzzle: Puzzle,
        messages: [Message],
        isWon: Bool,
        questionCount: Int
    ) async throws -> GameReview {
        let endpoint = config.baseURL.appendingPathComponent("api/v1/generate-review")

        // Serialize transcript turns. Server-side prompt builder numbers user
        // turns 1..N so it can reference them in `key_moments[].turn`.
        let transcript: [[String: Any]] = messages.compactMap { msg in
            switch msg.role {
            case .user:
                return ["role": "user", "text": msg.text]
            case .assistant:
                var t: [String: Any] = ["role": "assistant", "text": msg.text]
                if let v = msg.verdict { t["verdict"] = v.rawValue }
                return t
            case .system:
                return nil
            }
        }

        let body: [String: Any] = [
            "puzzle": [
                "title":    puzzle.title,
                "scenario": puzzle.scenario,
                "answer":   puzzle.answer,
            ],
            "transcript":    transcript,
            "isWon":         isWon,
            "questionCount": questionCount,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let token = try await config.idTokenProvider()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.httpBody = bodyData

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ReviewError.invalidResponse("Not an HTTP response")
        }
        guard http.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "unknown"
            throw ReviewError.serverError(http.statusCode, errText)
        }

        let decoded = try JSONDecoder().decode(ReviewResponse.self, from: data)
        return decoded.review
    }

    // MARK: - Wire types

    private struct ReviewResponse: Decodable {
        let review: GameReview
    }

    // MARK: - Errors

    enum ReviewError: LocalizedError {
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
