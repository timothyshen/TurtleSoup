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
    /// Streamed-in review fields (summary / tip) in arrival order. Drives
    /// the progress UI while isGeneratingReview is true; cleared once the
    /// final aiReview lands.
    var reviewProgress: [(field: String, value: String)] = []
    /// Cached AI review from a previous play of this same puzzle. Loaded
    /// lazily on first .task call rather than in init — init runs on every
    /// SwiftUI body eval (via State(wrappedValue:)) which triggers a
    /// CoreData fetch per frame and stalls sidebar-toggle animations.
    /// Surfaced in the answer sheet when the current game has no aiReview
    /// yet so the player can re-read it without paying for regeneration.
    var pastReview: GameReview? = nil

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
    /// Handle to the in-flight review-generation Task. Held so the UI can
    /// cancel it explicitly (cancel button) or implicitly (sheet dismiss).
    /// AsyncThrowingStream.onTermination propagates the cancellation down
    /// to the underlying URLSession task, so the network request actually
    /// stops — not just the consumer loop.
    private var reviewTask: Task<Void, Never>? = nil

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
        // Past review intentionally NOT loaded here — see loadPastReview().
    }

    /// Lazily load the cached past review. Call this from .task on the
    /// view, NOT from init: init runs on every SwiftUI body eval via
    /// State(wrappedValue:) which would hit CoreData per frame and stall
    /// sidebar-toggle animations.
    func loadPastReview() {
        guard pastReview == nil else { return }
        pastReview = recordStore.latestReview(for: puzzle.id)
    }

    convenience init(puzzle: Puzzle, claudeConfig: ClaudeService.Config, recordStore: GameRecordStore, isPublicPuzzle: Bool = false) {
        self.init(
            puzzle: puzzle,
            claude: ClaudeService(config: claudeConfig),
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
                let stream = await claude.sendStream(
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

    /// Kick off review generation. Wraps the async work in a Task so the
    /// UI can cancel it (cancel button or sheet dismiss). Safe to call
    /// from a synchronous SwiftUI action handler — no need for the caller
    /// to spin up its own Task.
    func startReviewGeneration(config: ReviewService.Config) {
        // Don't double-start; the in-flight task will populate everything.
        guard aiReview == nil, !isGeneratingReview else { return }
        reviewTask = Task { [weak self] in
            await self?.generateReview(config: config)
        }
    }

    /// Cancel an in-flight review. The AsyncThrowingStream's onTermination
    /// hook propagates this down to URLSession so the network request
    /// stops too — we don't just orphan it. UI state (isGeneratingReview,
    /// reviewProgress) gets reset to pre-streaming so the sheet shows the
    /// "生成 AI 复盘" button again.
    func cancelReviewGeneration() {
        reviewTask?.cancel()
        reviewTask = nil
        isGeneratingReview = false
        reviewProgress = []
        // Leave reviewError alone — if it's set, the user should see why.
    }

    /// Generate a post-game AI review and persist it onto the saved record.
    /// No-op if a review already exists or no record has been saved (mid-game).
    /// Streams progress events so the answer sheet can render a per-field
    /// checklist instead of a blank spinner.
    ///
    /// Prefer `startReviewGeneration(config:)` from UI code — it owns the
    /// cancel-able Task handle and shields callers from threading details.
    func generateReview(config: ReviewService.Config) async {
        guard aiReview == nil, !isGeneratingReview else { return }
        guard let recordID = lastSavedRecordID else {
            // Should only happen if called before persistRecord — bail quietly.
            return
        }

        isGeneratingReview = true
        reviewError = nil
        reviewProgress = []
        defer {
            isGeneratingReview = false
            reviewTask = nil
        }

        do {
            let service = ReviewService(config: config)
            let stream = await service.generateStream(
                puzzle: puzzle,
                messages: messages.filter { $0.role != .system },
                isWon: isGameWon,
                questionCount: questionCount
            )
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .progress(let field, let value):
                    if !reviewProgress.contains(where: { $0.field == field }) {
                        reviewProgress.append((field: field, value: value))
                    }
                case .complete(let review):
                    recordStore.updateAIReview(recordID: recordID, review: review)
                    aiReview = review
                }
            }
        } catch is CancellationError {
            // Expected on user-initiated cancel; cancelReviewGeneration
            // already reset the UI state. Don't surface as an error.
        } catch {
            reviewError = error.localizedDescription
        }
    }
}
