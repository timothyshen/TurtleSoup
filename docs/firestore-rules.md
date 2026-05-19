# Firestore Security Rules

Apply these rules in **Firebase Console → Firestore Database → Rules**.

The `/rooms/{code}` rules support the multiplayer-rooms feature
(`docs/plans/2026-05-19-multiplayer-rooms.md`). Deploy them only when the
iPhone client is ready to consume them — until then they're harmless but
unused.

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // ─── Per-user private data ────────────────────────────────────────────
    // Users can only read/write their own data.
    match /users/{uid}/{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }

    // ─── Public puzzles ───────────────────────────────────────────────────
    // Anyone can read; only the author can write.
    match /publicPuzzles/{puzzleId} {
      allow read: if true;
      allow write: if request.auth != null
                   && request.resource.data.authorUID == request.auth.uid;
    }

    // ─── Multiplayer rooms ────────────────────────────────────────────────
    // Host-as-GM architecture: the host's device adjudicates questions
    // and writes verdicts. Puzzle answers are NEVER stored in Firestore.
    // See docs/plans/2026-05-19-multiplayer-rooms.md for the full design.

    match /rooms/{roomCode} {
      // Anyone authenticated can read a room doc — needed for the join
      // flow (type code → look up → decide to join). Room docs contain
      // no secrets (no answer).
      allow read: if request.auth != null;

      allow create: if request.auth != null
                    && request.resource.data.hostUid == request.auth.uid
                    && request.resource.data.code == roomCode;

      allow update: if request.auth != null
                    && resource.data.hostUid == request.auth.uid;

      allow delete: if request.auth != null
                    && resource.data.hostUid == request.auth.uid;

      // Participants subcollection: who's in the room.
      match /participants/{participantUid} {
        allow read: if request.auth != null;

        // Self-join: doc id must equal your uid and the uid field too.
        allow create: if request.auth != null
                      && participantUid == request.auth.uid
                      && request.resource.data.uid == request.auth.uid;

        // Update own doc (display name, etc.) OR the host can update
        // anyone (scoring, elimination flags).
        allow update: if request.auth != null
                      && (participantUid == request.auth.uid
                          || get(/databases/$(database)/documents/rooms/$(roomCode)).data.hostUid == request.auth.uid);

        // Leave the room yourself, or host kicks.
        allow delete: if request.auth != null
                      && (participantUid == request.auth.uid
                          || get(/databases/$(database)/documents/rooms/$(roomCode)).data.hostUid == request.auth.uid);
      }

      // Rounds: one per puzzle played. Host owns these.
      match /rounds/{roundIndex} {
        // Round docs hold scenario/hint — readable by all room participants.
        // Answer is NOT stored here.
        allow read: if request.auth != null;

        // Only the host writes round state (status transitions, winner,
        // puzzle metadata).
        allow write: if request.auth != null
                     && get(/databases/$(database)/documents/rooms/$(roomCode)).data.hostUid == request.auth.uid;

        // Turns: questions and verdicts for this round.
        match /turns/{turnId} {
          allow read: if request.auth != null;

          // Creation enforced in rules (not just clients): the asker must
          // be the current questioner for the round, status must be
          // active, and verdict must start as null. Off-turn questioning
          // is impossible.
          allow create: if request.auth != null
                        && request.resource.data.askerUid == request.auth.uid
                        && request.resource.data.verdict == null
                        && get(/databases/$(database)/documents/rooms/$(roomCode)/rounds/$(roundIndex)).data.questionerUid == request.auth.uid
                        && get(/databases/$(database)/documents/rooms/$(roomCode)/rounds/$(roundIndex)).data.status == "active";

          // Only the host writes verdicts. They can't alter the question
          // text or the asker — that's audit-immutable.
          allow update: if request.auth != null
                        && get(/databases/$(database)/documents/rooms/$(roomCode)).data.hostUid == request.auth.uid
                        && resource.data.askerUid == request.resource.data.askerUid
                        && resource.data.text      == request.resource.data.text;

          // Turns are immutable history; never deletable.
          allow delete: if false;
        }
      }
    }
  }
}
```

## Data Schema

```
/users/{uid}/
  gameRecords/{recordId}/                  (single-player only)
    id            : String (UUID)
    puzzleID      : String (UUID)
    puzzleTitle   : String
    startedAt     : Timestamp
    endedAt       : Timestamp
    isWon         : Bool
    questionCount : Int
    aiReview      : String?                (JSON-encoded GameReview)
    messagesJSON  : String?                (JSON-encoded [Message])

  puzzles/{puzzleId}/
    id            : String (UUID)
    title         : String
    difficulty    : String ("简单" | "中等" | "困难")
    scenario      : String
    answer        : String
    hint          : String? (optional)
    author        : String
    playCount     : Int

/publicPuzzles/{puzzleId}/
  id            : String (UUID)
  title         : String
  difficulty    : String
  scenario      : String
  answer        : String
  hint          : String? (optional)
  author        : String
  playCount     : Int
  authorUID     : String (Firebase UID)
  publishedAt   : Timestamp (server timestamp)

/rooms/{roomCode}/                         (multiplayer; doc id == 6-char code)
  code              : String
  hostUid           : String
  hostDisplayName   : String
  mode              : "party" | "elimination"
  status            : "waiting" | "running" | "finished"
  createdAt         : Timestamp
  startedAt         : Timestamp?
  finishedAt        : Timestamp?
  currentRoundIndex : Int                  (-1 before first round)
  settings          : {
    maxRounds              : Int            (party only)
    questionerRotation     : "sequential" | "random"
    maxQuestionsPerRound   : Int?           (elimination only)
  }

  /participants/{uid}/
    uid              : String
    displayName      : String
    joinedAt         : Timestamp
    isHost           : Bool
    isEliminated     : Bool
    score            : Int
    fastestSolveSecs : Int?
    questionsAsked   : Int
    roundsWon        : Int

  /rounds/{roundIndex}/                    (n = 0..maxRounds-1)
    index            : Int
    questionerUid    : String
    puzzleScenario   : String              (public — answer NOT stored)
    puzzleHint       : String?
    puzzleAuthor     : String?
    puzzleTitle      : String?
    puzzleDifficulty : String
    status           : "waiting" | "active" | "won" | "abandoned"
    startedAt        : Timestamp?
    endedAt          : Timestamp?
    winnerUid        : String?
    questionCount    : Int

    /turns/{turnId}/
      id               : String
      askerUid         : String
      askerDisplayName : String
      text             : String
      askedAt          : Timestamp
      verdict          : String?           (null until host adjudicates)
      comment          : String?
      adjudicatedAt    : Timestamp?
```
