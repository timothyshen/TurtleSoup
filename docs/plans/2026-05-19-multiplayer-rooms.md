# Multiplayer Rooms — Design Spec

**Status:** spec only. macOS app unchanged. iPhone client (future project) implements against this.

## 1. Goal

In-person party gameplay where one player (the **host**) creates a room and others (**participants**) join via a 6-char code. Multiple rounds per session, two end-game modes selectable at room creation:

- **Party** — fixed 3-10 puzzle rounds, leaderboard at end with multiple win categories
- **Elimination** — last person standing wins; questioner who fails to win their turn is eliminated

## 2. Architecture — Host-as-GM

The trickiest constraint: participants must never see the puzzle answer (汤底), but the answer is required to validate each question against Claude.

The standard "thin client + cloud authority" answer would be Cloud Functions reading the answer via Admin SDK. We deliberately avoid this — adds infrastructure (firebase-admin doesn't run on Vercel Edge, Cloud Functions need Blaze plan which user has declined).

Instead: **the host's device is the game master**. The host holds the puzzle locally (including the answer), listens to a Firestore turns collection for participant questions, calls the existing `/api/v1/messages` proxy with the answer in the system prompt, and writes the verdict back to Firestore. Participants see only scenario + verdicts.

```
┌─────────────┐      questions      ┌─────────────────┐
│ Participant │ ──── write turn ──▶ │ Firestore       │
│   device    │                     │ rooms/{code}/   │
│             │ ◀── verdict watch ──│   rounds/{n}/   │
└─────────────┘                     │     turns/{tid} │
                                    └────────┬────────┘
                                             │ host's listener
                                             ▼
                                    ┌─────────────────┐
                                    │ Host device     │
                                    │ - holds answer  │ ──▶ /api/v1/messages
                                    │   in memory     │     (Claude verdict)
                                    │ - writes verdict│
                                    └─────────────────┘
```

**Trade-offs:**
- ✅ Answer never traverses Firestore, proxy, or other clients
- ✅ No new proxy endpoints — reuses existing `/v1/messages`
- ✅ Security rules stay document-level (no field-level masking)
- ⚠️ Host disconnect halts the game (acceptable for in-person parties; host migration is a v2 problem)
- ⚠️ Host runs all Claude calls under their own auth, paying for the room's tokens

## 3. Firestore Schema

```
/rooms/{roomCode}/                      (document)
  code                  : string        (6-char uppercase, == doc id)
  hostUid               : string
  hostDisplayName       : string
  mode                  : "party" | "elimination"
  status                : "waiting" | "running" | "finished"
  createdAt             : Timestamp
  startedAt             : Timestamp?    (when first round began)
  finishedAt            : Timestamp?
  currentRoundIndex     : int           (-1 before first round)
  settings              : {
    maxRounds           : int           (party mode; 3..10)
    questionerRotation  : "sequential" | "random"
  }

  /participants/{uid}/                  (subcollection)
    uid                 : string
    displayName         : string
    joinedAt            : Timestamp
    isHost              : bool
    isEliminated        : bool          (elimination mode)
    score               : int           (party mode; aggregate over rounds)
    fastestSolveSecs    : int?          (party mode; for awards)
    questionsAsked      : int           (party mode; for "fewest questions" award)
    roundsWon           : int

  /rounds/{n}/                          (subcollection; n = roundIndex, 0-based)
    index               : int
    questionerUid       : string        (whose turn to ask THIS round)
    puzzleScenario      : string        (visible to all participants)
    puzzleHint          : string?
    puzzleAuthor        : string?
    puzzleTitle         : string?
    puzzleDifficulty    : "简单" | "中等" | "困难"
    status              : "waiting" | "active" | "won" | "abandoned"
    startedAt           : Timestamp?
    endedAt             : Timestamp?
    winnerUid           : string?
    questionCount       : int
    // PUZZLE ANSWER IS DELIBERATELY NOT STORED HERE.

    /turns/{turnId}/                    (sub-subcollection)
      id                : string
      askerUid          : string
      text              : string        (the question)
      askerDisplayName  : string        (denormalized for render speed)
      askedAt           : Timestamp
      verdict           : "yes"|"no"|"irr"|"part"|"win" | null  // null = pending
      comment           : string?
      adjudicatedAt     : Timestamp?
```

### Why the puzzle metadata is denormalized into the round doc

Participants need to see scenario/hint at all times. If we kept a reference (`puzzleID`) instead, every client would need to query `puzzles/{id}` or `publicPuzzles/{id}` to render — extra reads, extra rules complexity. Inlining the safe parts keeps reads cheap and bounded to the room subtree.

### Why no separate `chats/` or `messages/` for cross-round chat

Out of scope. Each round's `turns/` IS the chat for that puzzle. If we add free-form chat later it goes under `rooms/{code}/messages/`.

## 4. Security Rules

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // (existing rules omitted)

    match /rooms/{roomCode} {
      // Anyone authenticated can read a room doc (needed for join flow:
      // type code, see if it exists, decide to join). Participants get
      // their own membership doc below.
      allow read: if request.auth != null;

      // Only the host can create (and they set themselves as host).
      allow create: if request.auth != null
                    && request.resource.data.hostUid == request.auth.uid
                    && request.resource.data.code == roomCode;

      // Only the host can update the room doc (status transitions,
      // round index advances, settings).
      allow update: if request.auth != null
                    && resource.data.hostUid == request.auth.uid;

      // Host can delete; cleanup also allowed by host.
      allow delete: if request.auth != null
                    && resource.data.hostUid == request.auth.uid;

      match /participants/{participantUid} {
        // Everyone in the room can see who else is in it.
        allow read: if request.auth != null;

        // A user can create their own participant doc (joining), and
        // the doc's uid must match their auth uid.
        allow create: if request.auth != null
                      && participantUid == request.auth.uid
                      && request.resource.data.uid == request.auth.uid;

        // Users can update their own participant doc (e.g. display name);
        // the host can update anyone's (for scoring + elimination).
        allow update: if request.auth != null
                      && (participantUid == request.auth.uid
                          || get(/databases/$(database)/documents/rooms/$(roomCode)).data.hostUid == request.auth.uid);

        // Users can leave (delete their own membership); host can boot.
        allow delete: if request.auth != null
                      && (participantUid == request.auth.uid
                          || get(/databases/$(database)/documents/rooms/$(roomCode)).data.hostUid == request.auth.uid);
      }

      match /rounds/{roundIndex} {
        // All authenticated users can read round state (scenario, status, ...).
        // The answer is not in this document, so this is safe.
        allow read: if request.auth != null;

        // Only the host writes round documents.
        allow write: if request.auth != null
                     && get(/databases/$(database)/documents/rooms/$(roomCode)).data.hostUid == request.auth.uid;

        match /turns/{turnId} {
          // Anyone in the room sees the question log.
          allow read: if request.auth != null;

          // Participants create turns ONLY with their own uid as asker and
          // ONLY when they're the current questioner for the round. Strict
          // checks here prevent off-turn questioning.
          allow create: if request.auth != null
                        && request.resource.data.askerUid == request.auth.uid
                        && request.resource.data.verdict == null
                        && get(/databases/$(database)/documents/rooms/$(roomCode)/rounds/$(roundIndex)).data.questionerUid == request.auth.uid
                        && get(/databases/$(database)/documents/rooms/$(roomCode)/rounds/$(roundIndex)).data.status == "active";

          // Only the host updates a turn (writing the verdict + comment).
          allow update: if request.auth != null
                        && get(/databases/$(database)/documents/rooms/$(roomCode)).data.hostUid == request.auth.uid
                        && resource.data.askerUid == request.resource.data.askerUid  // can't change asker
                        && resource.data.text      == request.resource.data.text;     // can't rewrite question

          allow delete: if false;  // turns are immutable history
        }
      }
    }
  }
}
```

### Notable rule decisions

- **Reads are open to all authenticated users**, not gated to participants. Rationale: the join flow needs `read` before there's a membership doc. The room contains nothing secret (no answer). If we later need privacy, we can gate reads on participant doc existence.

- **Turn creation enforces turn order in the rules**, not just the client. Without this, any participant could write a turn at any time and bypass the rotation. The cross-doc `get()` is one read per write — acceptable.

- **Turns are immutable** (`update` only via the verdict path; no delete). Audit trail.

## 5. State Machines

### Room lifecycle
```
        ┌─ creation ─┐
        │            ▼
        │       ┌────────┐
        │       │waiting │ ← host can start whenever participants joined
        │       └───┬────┘
        │           │ host starts first round
        │           ▼
        │       ┌────────┐
host ───┤       │running │ ◀───┐
        │       └───┬────┘     │ next round
        │           │ all rounds done │  or elimination final
        │           │ or host stops   │
        │           ▼                 │
        │       ┌──────────┐          │
        └──────▶│ finished │◀─────────┘
                └──────────┘
```

### Round lifecycle
```
   waiting (round doc created, puzzle picked, questioner set)
      │
      │ host activates
      ▼
   active ───────────┐
      │              │ winner verdict OR host calls it
      │              ▼
      │           won
      │ ┌────────────┘
      │ │
      ▼ ▼
   abandoned (questioner gave up or skipped)
```

### Participant lifecycle (elimination mode)
```
   active ──── their turn as questioner ──── solved → active (next round)
      │                                      not solved → eliminated
      │
      └── voluntary leave → removed
```

## 6. Mode Specifics

### Party mode

- Total rounds: `settings.maxRounds` (3-10, configurable at create time)
- Questioner rotates each round (`questionerRotation: "sequential"` walks the participants list; `"random"` picks any non-prior questioner)
- Every participant gets ≈ equal turns as questioner
- Score per win: 1 point base + speed bonus (`max(0, 60 - secondsToSolve / 5)` or similar — finalize when implementing)
- End-of-game awards:
  - 🥇 **冠军** — highest total score
  - ⚡ **最快通关** — lowest fastestSolveSecs across all wins
  - 🎯 **最高效** — best (won / asked) ratio
  - 🤔 **最爱问** — highest total questionsAsked (consolation)

### Elimination mode

- No fixed round count
- Every round, the current questioner MUST solve their puzzle. If they give up or hit a question limit (say `settings.maxQuestionsPerRound`), they're eliminated.
- Last unelimianted participant wins.
- Edge: if only one participant remains AND they haven't taken a turn yet, declare them winner immediately.

## 7. Room Code Generation

6 characters from the alphabet `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (32 chars, removes 0/O/I/1 ambiguity). 32^6 ≈ 1 billion combinations.

Host's client mints the code:
```
function mintRoomCode() async -> String {
  for attempt in 1...10 {
    let code = randomCode(length: 6)
    let docRef = db.collection("rooms").document(code)
    let snapshot = try await docRef.getDocument()
    if !snapshot.exists {
      // Create with a transaction to be safe under concurrent attempts.
      try await docRef.setData(initialRoomDoc)
      return code
    }
  }
  throw RoomError.codeGenerationFailed
}
```

In practice collisions are astronomically rare; the retry loop is belt-and-suspenders for an edge case.

## 8. Host's Question Adjudication Flow

When the host's device is running, it maintains a Firestore listener on
`rooms/{code}/rounds/{currentRoundIndex}/turns/` filtered to `verdict == null`.

```
for new pending turn:
  request = build_claude_messages_request(
    history: previously-adjudicated turns,
    userInput: turn.text,
    puzzle: localPuzzle    // includes answer
  )
  response = call_proxy_messages_with_streaming(request)
  await first complete event
  
  if response.verdict == "win":
    // 1. Update the turn doc with verdict + comment
    // 2. Update the round doc: status="won", winnerUid=turn.askerUid, endedAt
    // 3. Update the winner's participants doc: roundsWon++, score+=delta
    // 4. If party mode and currentRoundIndex+1 < maxRounds: start next round
    // 5. Else: room status="finished"
  else:
    // Just update the turn doc
```

All multi-doc updates happen inside Firestore transactions so participants never see a half-updated state.

## 9. Edge Cases

### Host disconnect mid-round
Participants see no new verdicts. After a 30-second timeout with no host activity:
- Show "host disconnected" banner
- Allow majority vote to promote a new host (deferred to v2; for v1 just show the banner and wait)

### Participant disconnect
Their participant doc stays. They can rejoin (their uid is the doc key). Other participants see them grayed out. If it's their turn as questioner, the host can manually skip.

### Concurrent question writes
The rule `questionerUid == request.auth.uid` ensures only the current questioner can write. If two people race, only one passes the rule check.

### Host changes the puzzle mid-round
Forbidden by clients; trivially enforceable in security rules (the round doc's puzzle fields can be set on create only). Not enforced in v1 rules above; add if it becomes an issue.

### Code typo / room not found
Join flow: read `rooms/{code}` first. If `!exists`, show "房间码不存在". If `status == "finished"`, show "房间已结束". Only proceed to write participant doc otherwise.

### Same uid joins twice
Idempotent: the participant doc key is the uid. Second join updates rather than creates. The displayName edit case is also handled by the update rule.

## 10. What's NOT in this design

- **Reconnect after force quit** — listeners reattach on cold start; SwiftUI handles it. No special logic needed.
- **Spectator mode** — anyone authenticated can read room state today (security rules above). UI can show a "as spectator" path if `participants/{my_uid}` doesn't exist.
- **AI-generated puzzles per round** — host picks from their library OR public square. Future: integrate `/api/v1/generate-puzzle` so each round is fresh AI. Out of scope for v1.
- **Cross-platform** — iPhone client only. The macOS app stays single-player.
- **Voice/video chat** — out of scope. Use FaceTime in another window.
- **Persistent rooms across days** — rooms auto-delete (TTL via a scheduled function) after 24h. Out of scope; for now they accumulate.

## 11. Implementation Order (for the iPhone project)

When the iPhone project picks this up:

1. **Firestore rules deploy** — update `docs/firestore-rules.md`, deploy to Firebase Console.
2. **Models** — `Room`, `Participant`, `Round`, `Turn` structs mirroring the schema. Codable.
3. **RoomService** — actor wrapping `rooms/{code}/...` CRUD via Firestore SDK. Subscribe + write helpers.
4. **Room create flow** — host UI: enter display name, choose mode + settings, mint code, share via UIActivityViewController.
5. **Room join flow** — participant UI: enter code, display name, tap join.
6. **Lobby** — list of participants, host has "start" button.
7. **Round UI** — questioner sees question box, others see read-only feed. Verdicts stream in via listener.
8. **Host adjudication loop** — combine the new turns listener with existing `ClaudeService.sendStream`, write verdicts.
9. **End-of-game screens** — leaderboard (party) / winner reveal (elimination).
10. **Polish** — host disconnect banner, rejoin handling, code-not-found errors.

Estimated work for iPhone v1 of this feature: ~2-3 weeks given an iPhone codebase exists. Most of the Models and ClaudeService can be lifted directly from the macOS app (or made universal in a shared package).
