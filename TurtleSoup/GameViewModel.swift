import Foundation
import Observation

@Observable
@MainActor
final class GameViewModel {

    var messages: [Message] = []
    var inputText: String = ""
    var isLoading: Bool = false
    var isGameWon: Bool = false
    var showGiveUpConfirm: Bool = false
    var questionCount: Int = 0
    var errorMessage: String? = nil
    var showAnswer: Bool = false

    // AI review state — populated when the player taps "生成 AI 复盘" in
    // the answer sheet. Kept in-memory for the current session and persisted
    // through recordStore.updateAIReview on success.
    var aiReview: GameReview? = nil
    var isGeneratingReview: Bool = false
    var reviewError: String? = nil

    let puzzle: Puzzle
    private let recordStore: GameRecordStore
    private let startedAt: Date = Date()
    private let claude: ClaudeService
    /// True when this puzzle was selected from the public square. Drives the
    /// publicPuzzles/{id}.playCount writeback on game end.
    private let isPublicPuzzle: Bool
    /// Set after the first persistRecord call so generateReview knows which
    /// CoreData row to attach the review to.
    private var lastSavedRecordID: UUID? = nil

    /// Designated init. Tests use this with a `ClaudeService` constructed
    /// against a mocked URLSession; production code uses the Transport
    /// convenience init below.
    init(puzzle: Puzzle, claude: ClaudeService, recordStore: GameRecordStore, isPublicPuzzle: Bool = false) {
        self.recordStore = recordStore
        self.puzzle = puzzle
        self.claude = claude
        self.isPublicPuzzle = isPublicPuzzle
        self.messages = [
            Message(role: .system,
                    text: "游戏开始——你可以用陈述或问句来探索真相，主持人只回答：是 / 否 / 无关 / 部分正确")
        ]
    }

    convenience init(puzzle: Puzzle, transport: ClaudeService.Transport, recordStore: GameRecordStore, isPublicPuzzle: Bool = false) {
        self.init(
            puzzle: puzzle,
            claude: ClaudeService(transport: transport),
            recordStore: recordStore,
            isPublicPuzzle: isPublicPuzzle
        )
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading, !isGameWon else { return }

        inputText = ""
        questionCount += 1
        let historySnapshot = messages   // capture before mutating
        messages.append(Message(role: .user, text: text))

        isLoading = true
        errorMessage = nil

        // Streaming send: an empty assistant placeholder goes in first, then
        // we fill its verdict (badge shows) and text (bubble appears) as
        // events arrive. If anything throws, we strip the placeholder so the
        // chat doesn't show a ghost bubble.
        let placeholderID = UUID()
        let placeholder = Message(
            id: placeholderID, role: .assistant, text: "",
            verdict: nil, timestamp: Date()
        )
        messages.append(placeholder)

        Task {
            var finalVerdict: Message.Verdict? = nil
            do {
                let stream = claude.sendStream(
                    userInput: text,
                    history: historySnapshot,
                    puzzle: puzzle
                )
                for try await event in stream {
                    switch event {
                    case .verdictReady(let raw):
                        let v = Message.Verdict(rawValue: raw) ?? .irr
                        updatePlaceholder(id: placeholderID) { $0.verdict = v }
                    case .complete(let response):
                        let verdict = Message.Verdict(rawValue: response.verdict) ?? .irr
                        let comment = response.comment.isEmpty ? verdict.label : response.comment
                        replacePlaceholder(
                            id: placeholderID,
                            with: Message(role: .assistant, text: comment, verdict: verdict)
                        )
                        finalVerdict = verdict
                    }
                }

                if finalVerdict == .win {
                    isGameWon = true
                    persistRecord(isWon: true)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    showAnswer = true
                }
            } catch {
                errorMessage = error.localizedDescription
                // Drop the placeholder so the chat history doesn't show a
                // half-filled bubble after a failure.
                messages.removeAll { $0.id == placeholderID }
            }
            isLoading = false
        }
    }

    /// In-place update of an existing message identified by `id`. Used to
    /// flash the verdict badge before the comment text arrives.
    private func updatePlaceholder(id: UUID, mutate: (inout Message) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        var msg = messages[i]
        mutate(&msg)
        messages[i] = msg
    }

    /// Full replacement when the final response is parsed. Preserves the
    /// placeholder's position so the bubble doesn't jump in the scroll view.
    private func replacePlaceholder(id: UUID, with newMessage: Message) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else {
            messages.append(newMessage)
            return
        }
        messages[i] = newMessage
    }

    func giveUp() {
        guard !isGameWon else { return }
        isGameWon = true
        persistRecord(isWon: false)
        showAnswer = true
    }

    private func persistRecord(isWon: Bool) {
        let record = GameRecord(
            puzzleID:      puzzle.id,
            puzzleTitle:   puzzle.title,
            startedAt:     startedAt,
            endedAt:       Date(),
            isWon:         isWon,
            questionCount: questionCount,
            messages:      messages.filter { $0.role != .system }
        )
        lastSavedRecordID = record.id
        recordStore.saveRecord(record)

        // For public-square puzzles, bump the global play counter. Counts both
        // wins and give-ups (mirrors local playCount semantics).
        if isPublicPuzzle {
            recordStore.incrementPublicPlayCount(puzzleID: puzzle.id)
        }
    }

    // MARK: - AI review

    /// Generate a post-game AI review and persist it onto the saved record.
    /// No-op if a review already exists or no record has been saved (mid-game).
    func generateReview(config: ReviewService.Config) async {
        guard aiReview == nil, !isGeneratingReview else { return }
        guard let recordID = lastSavedRecordID else {
            // Should only happen if called before persistRecord — bail quietly.
            return
        }

        isGeneratingReview = true
        reviewError = nil
        defer { isGeneratingReview = false }

        do {
            let service = ReviewService(config: config)
            let review = try await service.generate(
                puzzle: puzzle,
                messages: messages.filter { $0.role != .system },
                isWon: isGameWon,
                questionCount: questionCount
            )
            recordStore.updateAIReview(recordID: recordID, review: review)
            aiReview = review
        } catch {
            reviewError = error.localizedDescription
        }
    }
}
