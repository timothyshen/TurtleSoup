import Foundation
import Observation
import os.log

// MARK: - HostAdjudicator
//
// The host device's "GM brain" for multiplayer rounds. Owns the puzzle
// (including the secret answer that NEVER touches Firestore) and watches
// the current round's turn feed; whenever a participant submits a new
// pending turn, this class:
//
//   1. Replays the round's adjudicated history as a Claude message array
//      (so context like "earlier you said it's not about money" carries),
//   2. Streams a verdict through the existing /v1/messages proxy,
//   3. Writes the verdict back to Firestore via RoomService (which closes
//      the round and bumps participant tallies on .win in one transaction).
//
// Lifetime: created when the host's UI enters an active round, kept alive
// as long as the host is in the room. setPuzzle(...) is called every time
// the host picks a puzzle for a new round; processedTurnIds is reset so
// the new round starts clean.
//
// Why not run this inside RoomService? RoomService is generic to host AND
// participants. Only the host needs Claude calls — pulling the adjudicator
// out keeps RoomService's responsibilities narrow and means participants
// don't even instantiate the Claude path.

@MainActor
@Observable
final class HostAdjudicator {

    // MARK: - Configuration

    /// Currently active puzzle for THIS round. The answer field is the
    /// secret — never written to Firestore. nil between rounds.
    private(set) var puzzle: Puzzle?

    /// True while a Claude request is in flight. Surfaced to the host's
    /// UI so it can show a spinner ("正在裁决…") next to the pending turn.
    private(set) var isAdjudicating = false

    /// Last error from an adjudication attempt. UI clears after display.
    var lastError: String?

    // MARK: - Dependencies

    private let roomService: RoomService
    private let claudeConfig: ClaudeService.Config
    private let logger = Logger(subsystem: "com.haiguitang", category: "HostAdjudicator")

    // MARK: - Internal state

    private var claudeService: ClaudeService?     // built lazily; needs a URLSession on the main isolate
    private var watcherTask: Task<Void, Never>?
    private var inFlightTurnId: String?
    /// Turn IDs we've already adjudicated (or attempted to adjudicate)
    /// during this puzzle. Prevents double-spending Claude calls on the
    /// same turn if the listener re-fires with the same content before
    /// our verdict write has propagated back.
    private var processedTurnIds: Set<String> = []

    init(roomService: RoomService, claudeConfig: ClaudeService.Config) {
        self.roomService = roomService
        self.claudeConfig = claudeConfig
    }

    // MARK: - Public API

    /// Called by the host's UI immediately before / after invoking
    /// RoomService.startNextRound. Resets the dedupe set so the new round
    /// can be adjudicated cleanly.
    func setPuzzle(_ p: Puzzle) {
        puzzle = p
        processedTurnIds.removeAll()
        inFlightTurnId = nil
    }

    /// Begin watching RoomService for new pending turns. Idempotent; safe
    /// to call from .onAppear of the host's RoomActiveView.
    func start() {
        if watcherTask != nil { return }
        if claudeService == nil {
            claudeService = ClaudeService(config: claudeConfig)
        }
        watcherTask = Task { [weak self] in
            await self?.watchLoop()
        }
    }

    /// Stop watching. Called when host leaves the room or the room ends.
    func stop() {
        watcherTask?.cancel()
        watcherTask = nil
    }

    // MARK: - Observation loop
    //
    // We rebuild an observation tracker on every iteration. `withObservationTracking`
    // fires its `onChange` exactly once when any read property mutates, so the
    // pattern is: read state → install tracker → suspend until change →
    // re-process → loop. Cancelling watcherTask cancels the continuation.

    private func watchLoop() async {
        while !Task.isCancelled {
            await processNextPendingTurn()
            // Wait for the next mutation on any read property below.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = roomService.turns
                    _ = roomService.currentRound
                    _ = roomService.room
                } onChange: {
                    cont.resume()
                }
            }
        }
    }

    /// One pass: pick the oldest pending turn we haven't processed yet,
    /// adjudicate it. If none, return.
    private func processNextPendingTurn() async {
        guard let puzzle = puzzle,
              let round = roomService.currentRound,
              round.status == .active,
              inFlightTurnId == nil else {
            return
        }
        let candidates = roomService.turns
            .filter { $0.isPending && !processedTurnIds.contains($0.id) }
            .sorted { $0.askedAt < $1.askedAt }

        guard let turn = candidates.first else { return }

        processedTurnIds.insert(turn.id)
        inFlightTurnId = turn.id
        await adjudicate(turn: turn, puzzle: puzzle, round: round)
        inFlightTurnId = nil
    }

    // MARK: - Adjudication

    private func adjudicate(turn: Turn, puzzle: Puzzle, round: Round) async {
        guard let claude = claudeService else { return }
        isAdjudicating = true
        defer { isAdjudicating = false }

        // Build history from previously-adjudicated turns in this round.
        // Each adjudicated turn becomes a (user, assistant) pair. The
        // current pending turn is passed as userInput, not history.
        let priorAdjudicated = roomService.turns
            .filter { !$0.isPending && $0.id != turn.id }
            .sorted { $0.askedAt < $1.askedAt }

        let history: [Message] = priorAdjudicated.flatMap { (t: Turn) -> [Message] in
            let userMsg = Message(
                id: UUID(),
                role: .user,
                text: t.text,
                verdict: nil,
                timestamp: t.askedAt
            )
            var msgs: [Message] = [userMsg]
            if let v = t.verdict {
                msgs.append(Message(
                    id: UUID(),
                    role: .assistant,
                    text: t.comment ?? v.label,
                    verdict: v,
                    timestamp: t.adjudicatedAt ?? t.askedAt
                ))
            }
            return msgs
        }

        do {
            // ClaudeService is an actor; sendStream returns synchronously
            // but the call itself hops onto the actor's executor, so await
            // is required even though we're consuming an AsyncStream after.
            let stream = await claude.sendStream(
                userInput: turn.text,
                history: history,
                puzzle: puzzle
            )

            var verdict: Message.Verdict = .irr
            var comment: String = ""
            for try await event in stream {
                switch event {
                case .verdictReady(let raw):
                    if let v = Message.Verdict(rawValue: raw) { verdict = v }
                case .complete(let resp):
                    if let v = Message.Verdict(rawValue: resp.verdict) { verdict = v }
                    comment = resp.comment
                }
            }

            let elapsed: Int? = {
                guard let started = round.startedAt else { return nil }
                return max(0, Int(Date().timeIntervalSince(started)))
            }()
            try await roomService.writeVerdict(
                turnId:      turn.id,
                verdict:     verdict,
                comment:     comment.isEmpty ? nil : comment,
                elapsedSecs: elapsed
            )
        } catch {
            logger.error("adjudicate failed for turn \(turn.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Release the dedupe so a retry pass can pick it up. The
            // listener will re-fire when state changes (e.g. another
            // turn arrives), and we'll try again.
            processedTurnIds.remove(turn.id)
            lastError = "裁决失败：\(error.localizedDescription)"
        }
    }
}
