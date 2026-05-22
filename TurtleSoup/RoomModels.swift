import Foundation

// MARK: - Room Models (Multiplayer)
//
// Pure value-type mirrors of the Firestore /rooms/{code} subtree, as
// specified in docs/plans/2026-05-19-multiplayer-rooms.md.
//
// Design choices:
//
// - All `nonisolated`. These are pure Sendable Codable structs — no actor
//   isolation needed and we need to construct them from background contexts
//   (RoomService listener tasks).
//
// - No `import FirebaseFirestore` here. Firestore-specific concerns
//   (Timestamp ↔ Date conversion, @DocumentID, snapshot decoding) live in
//   RoomService. Keeping models pure means unit tests don't need the
//   Firebase SDK and these structs travel cleanly into snapshots/state.
//
// - Identifiable IDs match the Firestore document keys so SwiftUI ForEach
//   keys are stable across snapshot reloads:
//     Room.id          = code        (6-char uppercase string)
//     Participant.id   = uid
//     Round.id         = index       (Int, 0-based)
//     Turn.id          = turnId      (String, client-generated UUID)
//
// - Verdict reuses `Message.Verdict` from the single-player code path —
//   the proxy returns the exact same enum set, so there's no reason to
//   define a parallel one.

// MARK: - Room

nonisolated struct Room: Identifiable, Codable, Equatable, Hashable {
    var id: String { code }

    let code: String           // 6-char uppercase, == doc id
    let hostUid: String
    let hostDisplayName: String
    let mode: Mode
    var status: Status
    let createdAt: Date
    var startedAt: Date?       // when first round began
    var finishedAt: Date?
    var currentRoundIndex: Int // -1 before first round
    var settings: Settings

    enum Mode: String, Codable, CaseIterable {
        case party
        case elimination

        var label: String {
            switch self {
            case .party:       return "派对模式"
            case .elimination: return "淘汰模式"
            }
        }

        var subtitle: String {
            switch self {
            case .party:       return "固定轮数，最终排行榜"
            case .elimination: return "猜不出就淘汰，最后一人胜"
            }
        }
    }

    enum Status: String, Codable {
        case waiting   // pre-game; participants can join
        case running   // a round is in progress
        case finished  // all rounds done or host ended

        var isTerminal: Bool { self == .finished }
    }

    struct Settings: Codable, Equatable, Hashable {
        var maxRounds: Int                  // party mode: 3..10
        var questionerRotation: Rotation

        enum Rotation: String, Codable, CaseIterable {
            case sequential
            case random

            var label: String {
                switch self {
                case .sequential: return "顺序轮换"
                case .random:     return "随机"
                }
            }
        }

        static let `default` = Settings(maxRounds: 5, questionerRotation: .sequential)
    }
}

// MARK: - Participant

nonisolated struct Participant: Identifiable, Codable, Equatable, Hashable {
    var id: String { uid }

    let uid: String
    var displayName: String
    let joinedAt: Date
    let isHost: Bool
    var isEliminated: Bool       // elimination mode only

    // Party-mode running tallies. Kept on every participant for simplicity
    // (elimination mode reads them as 0; not worth a discriminated union).
    var score: Int
    var fastestSolveSecs: Int?   // for "最快通关" award
    var questionsAsked: Int      // for "最爱问" / "最高效" awards
    var roundsWon: Int

    /// Builder for the initial state when a user joins a room.
    static func joining(uid: String, displayName: String, isHost: Bool, at: Date = .now) -> Participant {
        Participant(
            uid:              uid,
            displayName:      displayName,
            joinedAt:         at,
            isHost:           isHost,
            isEliminated:     false,
            score:            0,
            fastestSolveSecs: nil,
            questionsAsked:   0,
            roundsWon:        0
        )
    }
}

// MARK: - Round

nonisolated struct Round: Identifiable, Codable, Equatable, Hashable {
    var id: Int { index }

    let index: Int
    let questionerUid: String

    // The "safe" puzzle fields — scenario/hint/metadata. The ANSWER is
    // deliberately NOT in this struct nor in Firestore. It lives only in
    // the host's in-memory Puzzle reference. See multiplayer-rooms.md §2.
    let puzzleScenario: String
    let puzzleHint: String?
    let puzzleAuthor: String?
    let puzzleTitle: String?
    let puzzleDifficulty: Puzzle.Difficulty

    var status: Status
    var startedAt: Date?
    var endedAt: Date?
    var winnerUid: String?
    var questionCount: Int

    enum Status: String, Codable {
        case waiting       // round doc created, not yet active
        case active        // accepting turns
        case won           // a participant guessed correctly
        case abandoned     // questioner gave up or skipped

        var isTerminal: Bool { self == .won || self == .abandoned }
    }
}

// MARK: - Turn

nonisolated struct Turn: Identifiable, Codable, Equatable, Hashable {
    let id: String                   // client-generated UUID string
    let askerUid: String
    let askerDisplayName: String     // denormalized for render speed
    let text: String
    let askedAt: Date

    // nil until the host's adjudication loop writes back. This is the
    // signal the host's listener filters on (`verdict == null`).
    var verdict: Message.Verdict?
    var comment: String?
    var adjudicatedAt: Date?

    var isPending: Bool { verdict == nil }
}

// MARK: - Room Code Generation

/// 32-char alphabet — removes 0/O, 1/I/L ambiguity for spoken / written
/// codes ("the room is X-Y-Z..."). 32^6 ≈ 1.07 billion combinations,
/// collision probability is astronomically low even for thousands of
/// concurrent rooms. The retry loop in RoomService.createRoom is
/// belt-and-suspenders.
nonisolated enum RoomCode {
    static let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    static let length = 6

    static func mint() -> String {
        String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// Validate user input on the join screen. Trim + uppercase + verify
    /// length and alphabet so we don't issue a Firestore read for garbage.
    static func normalize(_ input: String) -> String? {
        let trimmed = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard trimmed.count == length else { return nil }
        guard trimmed.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return trimmed
    }
}
