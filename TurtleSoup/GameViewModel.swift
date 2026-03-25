import Foundation
import Observation

@Observable
@MainActor
final class GameViewModel {

    var messages: [Message] = []
    var inputText: String = ""
    var isLoading: Bool = false
    var isGameWon: Bool = false
    var questionCount: Int = 0
    var errorMessage: String? = nil
    var showAnswer: Bool = false

    let puzzle: Puzzle
    private let recordStore: GameRecordStore
    private let startedAt: Date = Date()
    private let claude: ClaudeService

    init(puzzle: Puzzle, apiKey: String, recordStore: GameRecordStore) {
        self.recordStore = recordStore
        self.puzzle = puzzle
        self.claude = ClaudeService(apiKey: apiKey)
        self.messages = [
            Message(role: .system,
                    text: "游戏开始——你可以用陈述或问句来探索真相，主持人只回答：是 / 否 / 无关 / 部分正确")
        ]
    }

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
                let comment = response.comment.isEmpty ? verdict.label : response.comment
                messages.append(Message(role: .assistant, text: comment, verdict: verdict))

                if verdict == .win {
                    isGameWon = true
                    persistRecord()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    showAnswer = true
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func persistRecord() {
        let record = GameRecord(
            puzzleID:      puzzle.id,
            puzzleTitle:   puzzle.title,
            startedAt:     startedAt,
            endedAt:       Date(),
            isWon:         true,
            questionCount: questionCount,
            messages:      messages.filter { $0.role != .system }
        )
        recordStore.saveRecord(record)
    }
}
