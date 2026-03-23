import Foundation
import SwiftUI

@MainActor
final class GameViewModel: ObservableObject {

    // MARK: - State

    @Published var messages: [Message] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var isGameWon: Bool = false
    @Published var questionCount: Int = 0
    @Published var errorMessage: String? = nil
    @Published var showAnswer: Bool = false   // 解谜成功后展示汤底

    let puzzle: Puzzle
    private let claude: ClaudeService

    // MARK: - Init

    init(puzzle: Puzzle, apiKey: String) {
        self.puzzle = puzzle
        self.claude = ClaudeService(apiKey: apiKey)
        self.messages = [
            Message(role: .system,
                    text: "游戏开始——你可以用陈述或问句来探索真相，主持人只回答：是 / 否 / 无关 / 部分正确")
        ]
    }

    // MARK: - Send

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading, !isGameWon else { return }

        inputText = ""
        questionCount += 1
        messages.append(Message(role: .user, text: text))

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let response = try await claude.send(
                    userInput: text,
                    history: messages,
                    puzzle: puzzle
                )

                let verdict = Message.Verdict(rawValue: response.verdict) ?? .irr
                let comment = response.comment.isEmpty
                    ? verdict.label
                    : response.comment

                messages.append(Message(role: .assistant, text: comment, verdict: verdict))

                if verdict == .win {
                    isGameWon = true
                    // 延迟 1 秒后自动展示汤底
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    showAnswer = true
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
