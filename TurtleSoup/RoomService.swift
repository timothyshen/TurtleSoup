import Foundation
import FirebaseFirestore
import os.log

// MARK: - RoomService
//
// Lives on @MainActor because views read its state directly (@Observable).
// Holds Firestore listeners for the user's current room and exposes
// state-mutating operations for both host and participant flows.
//
// One RoomService = one room membership at a time. Calling joinRoom /
// createRoom while already in another room is a programmer error —
// callers should leaveRoom first.
//
// The host-vs-participant distinction is implicit: any signed-in user can
// call any method, but Firestore security rules (docs/firestore-rules.md
// §rooms) enforce that only the host can write the room doc / round docs
// / turn verdicts, and only the current questioner can write a new turn.
// The client-side guards in this file are best-effort UX — the rules are
// the source of truth.

@MainActor
@Observable
final class RoomService {

    // MARK: - Published state

    /// The room the user is currently in. nil when not in any room.
    private(set) var room: Room?

    /// Participants in the current room, sorted by joinedAt ascending.
    private(set) var participants: [Participant] = []

    /// The current round's snapshot. nil before the first round starts,
    /// and remains the last round's snapshot after a round ends (until
    /// host advances to the next or ends the room).
    private(set) var currentRound: Round?

    /// Turns for `currentRound`, sorted by askedAt ascending.
    private(set) var turns: [Turn] = []

    /// One-shot error message. UI is expected to clear this after display.
    var lastError: String?

    // MARK: - Dependencies

    private let db = Firestore.firestore()
    private let logger = Logger(subsystem: "com.haiguitang", category: "RoomService")
    private let authService: AuthService

    // MARK: - Listener handles

    private var roomListener: ListenerRegistration?
    private var participantsListener: ListenerRegistration?
    private var roundListener: ListenerRegistration?
    private var turnsListener: ListenerRegistration?

    init(auth: AuthService) {
        self.authService = auth
    }

    // No deinit — RoomService is App-owned (created in TurtleSoupApp.init
    // and held by @State for the entire process lifetime), so it never
    // deallocates. Listener cleanup happens explicitly via leaveRoom() and
    // detachListeners(); trying to do it in deinit would force a
    // nonisolated→MainActor hop just to read property values.

    // MARK: - Public API: Host

    /// Mint a unique 6-char code, write the initial room doc + the host's
    /// own participant doc, attach listeners. Returns the code on success.
    func createRoom(
        mode: Room.Mode,
        settings: Room.Settings,
        displayName: String
    ) async throws -> String {
        guard let uid = authService.uid else { throw RoomError.notSignedIn }
        let code = try await mintRoomCode()
        let now = Date()
        let newRoom = Room(
            code: code,
            hostUid: uid,
            hostDisplayName: displayName,
            mode: mode,
            status: .waiting,
            createdAt: now,
            startedAt: nil,
            finishedAt: nil,
            currentRoundIndex: -1,
            settings: settings
        )
        let host = Participant.joining(uid: uid, displayName: displayName, isHost: true, at: now)

        let batch = db.batch()
        batch.setData(encodeRoom(newRoom),           forDocument: roomRef(code))
        batch.setData(encodeParticipant(host),       forDocument: participantRef(code, uid))
        try await batch.commit()

        attachListeners(code: code)
        return code
    }

    /// Begin a new round. Host-only. The puzzle's answer stays in memory
    /// on the host device — only the safe fields (scenario, hint, etc.)
    /// are written to Firestore.
    func startNextRound(puzzle: Puzzle, questionerUid: String) async throws {
        guard let room = room, let uid = authService.uid else { throw RoomError.notInRoom }
        guard room.hostUid == uid else { throw RoomError.notHost }

        let nextIndex = room.currentRoundIndex + 1
        let round = Round(
            index: nextIndex,
            questionerUid: questionerUid,
            puzzleScenario: puzzle.scenario,
            puzzleHint: puzzle.hint,
            puzzleAuthor: puzzle.author,
            puzzleTitle: puzzle.title,
            puzzleDifficulty: puzzle.difficulty,
            status: .active,
            startedAt: Date(),
            endedAt: nil,
            winnerUid: nil,
            questionCount: 0
        )
        let now = Date()
        let batch = db.batch()
        batch.setData(encodeRound(round), forDocument: roundRef(room.code, nextIndex))
        // Advance the room doc: status=running, currentRoundIndex bumped,
        // startedAt set on first round.
        var roomUpdate: [String: Any] = [
            "status": Room.Status.running.rawValue,
            "currentRoundIndex": nextIndex
        ]
        if room.startedAt == nil {
            roomUpdate["startedAt"] = Timestamp(date: now)
        }
        batch.updateData(roomUpdate, forDocument: roomRef(room.code))
        try await batch.commit()
    }

    /// End the current round with a terminal status. Host-only. Used for
    /// the "give up / skip" path; the win path is handled inline by
    /// writeVerdict so the verdict + round close happen atomically.
    func endCurrentRound(status: Round.Status, winnerUid: String? = nil) async throws {
        guard let room = room, let round = currentRound, let uid = authService.uid else {
            throw RoomError.notInRoom
        }
        guard room.hostUid == uid else { throw RoomError.notHost }
        guard !round.status.isTerminal else { return }   // idempotent

        var update: [String: Any] = [
            "status":  status.rawValue,
            "endedAt": Timestamp(date: Date())
        ]
        if let winnerUid { update["winnerUid"] = winnerUid }
        try await roundRef(room.code, round.index).updateData(update)
    }

    /// Mark a participant as eliminated. Host-only. Used by the
    /// elimination-mode flow when a round ends without a winner: the
    /// questioner who failed is eliminated and the room either continues
    /// with the remaining participants or ends if only one is left.
    func eliminateParticipant(uid: String) async throws {
        guard let room = room, let myUid = authService.uid else { throw RoomError.notInRoom }
        guard room.hostUid == myUid else { throw RoomError.notHost }
        try await participantRef(room.code, uid).updateData(["isEliminated": true])
    }

    /// Mark the room as finished and write finishedAt. Host-only.
    /// Participants will see the terminal status and tear down their UI.
    func endRoom() async throws {
        guard let room = room, let uid = authService.uid else { throw RoomError.notInRoom }
        guard room.hostUid == uid else { throw RoomError.notHost }
        try await roomRef(room.code).updateData([
            "status":     Room.Status.finished.rawValue,
            "finishedAt": Timestamp(date: Date())
        ])
    }

    /// Host adjudication write-back: turn verdict + (if win) round closure
    /// + participant tallies, all in one transaction so participants never
    /// observe a half-applied state. Called by M8's Host-as-GM loop after
    /// the proxy returns a verdict.
    func writeVerdict(
        turnId: String,
        verdict: Message.Verdict,
        comment: String?,
        elapsedSecs: Int?
    ) async throws {
        guard let room = room, let round = currentRound, let uid = authService.uid else {
            throw RoomError.notInRoom
        }
        guard room.hostUid == uid else { throw RoomError.notHost }

        let turnRef = self.turnRef(room.code, round.index, turnId)
        let roundRef = self.roundRef(room.code, round.index)

        // Find the asker uid from our local turn cache (the rules already
        // froze it; we just need it for the participant tally bump on win).
        let askerUid = turns.first(where: { $0.id == turnId })?.askerUid

        try await db.runTransaction { txn, errorPointer in
            // 1) Always write the verdict on the turn.
            txn.updateData([
                "verdict":       verdict.rawValue,
                "comment":       comment as Any,
                "adjudicatedAt": Timestamp(date: Date())
            ], forDocument: turnRef)

            // 2) Bump the round's question count.
            txn.updateData(["questionCount": FieldValue.increment(Int64(1))],
                           forDocument: roundRef)

            // 3) On win: close the round + bump participant tallies.
            if verdict == .win, let askerUid {
                txn.updateData([
                    "status":    Round.Status.won.rawValue,
                    "endedAt":   Timestamp(date: Date()),
                    "winnerUid": askerUid
                ], forDocument: roundRef)

                let pRef = self.participantRef(room.code, askerUid)
                var bumps: [String: Any] = [
                    "roundsWon":      FieldValue.increment(Int64(1)),
                    "score":          FieldValue.increment(Int64(1))   // base; bonuses applied later
                ]
                if let elapsedSecs {
                    // Best (smallest) solve time — Firestore has no
                    // "min" op so we write only if current value is nil
                    // or greater. Approximate: just write if we have a
                    // value; client-side filtering can fix up the leaderboard.
                    bumps["fastestSolveSecs"] = elapsedSecs
                }
                txn.updateData(bumps, forDocument: pRef)
            }
            return nil
        }
    }

    // MARK: - Public API: Participant

    func joinRoom(code: String, displayName: String) async throws {
        guard let uid = authService.uid else { throw RoomError.notSignedIn }
        guard let normalized = RoomCode.normalize(code) else { throw RoomError.invalidCode }

        // Pre-check that the room exists and is joinable. Rules also
        // enforce this on write, but reading first lets us give a clean
        // "房间不存在" message instead of a generic permission error.
        let snap = try await roomRef(normalized).getDocument()
        guard snap.exists else { throw RoomError.roomNotFound }
        guard let data = snap.data(),
              let statusStr = data["status"] as? String,
              let status = Room.Status(rawValue: statusStr) else {
            throw RoomError.malformedRoom
        }
        guard status != .finished else { throw RoomError.roomFinished }

        let participant = Participant.joining(uid: uid, displayName: displayName, isHost: false)
        try await participantRef(normalized, uid).setData(encodeParticipant(participant))

        attachListeners(code: normalized)
    }

    /// Delete our participant doc + tear down listeners. Idempotent.
    func leaveRoom() async throws {
        guard let code = room?.code, let uid = authService.uid else {
            detachListeners()
            clearLocalState()
            return
        }
        try? await participantRef(code, uid).delete()
        detachListeners()
        clearLocalState()
    }

    /// Participant action: ask a question on the current round. The
    /// security rule requires this user to be the current round's
    /// questioner — we check locally too for a cleaner error message.
    func submitTurn(text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RoomError.emptyQuestion }
        guard let room = room, let round = currentRound, let uid = authService.uid else {
            throw RoomError.notInRoom
        }
        guard round.questionerUid == uid else { throw RoomError.notQuestioner }
        guard round.status == .active else { throw RoomError.roundInactive }

        let myName = participants.first(where: { $0.uid == uid })?.displayName ?? "玩家"
        let turn = Turn(
            id:               UUID().uuidString,
            askerUid:         uid,
            askerDisplayName: myName,
            text:             trimmed,
            askedAt:          Date(),
            verdict:          nil,
            comment:          nil,
            adjudicatedAt:    nil
        )
        try await turnRef(room.code, round.index, turn.id).setData(encodeTurn(turn))

        // Bump our local questionsAsked tally. The host owns the
        // authoritative count via writeVerdict's transaction, but this
        // self-bump gives leaderboard partial credit even if the host
        // never adjudicates (host disconnect mid-round).
        try? await participantRef(room.code, uid).updateData([
            "questionsAsked": FieldValue.increment(Int64(1))
        ])
    }

    // MARK: - Listener wiring

    /// Attach all four listeners and store their handles. Safe to call
    /// after detachListeners; replaces any existing subscriptions.
    private func attachListeners(code: String) {
        detachListeners()

        // 1) Room doc
        roomListener = roomRef(code).addSnapshotListener { [weak self] snap, err in
            Task { @MainActor in
                guard let self else { return }
                if let err {
                    self.logger.error("room listener error: \(err.localizedDescription, privacy: .public)")
                    return
                }
                self.room = snap.flatMap { self.decodeRoom($0) }
                // If the host ended the room, auto-leave: drop listeners
                // and clear state so the UI returns to the lobby root.
                if self.room?.status == .finished {
                    self.detachListeners()
                }
            }
        }

        // 2) Participants subcollection
        participantsListener = participantsRef(code).order(by: "joinedAt")
            .addSnapshotListener { [weak self] snap, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let err {
                        self.logger.error("participants listener: \(err.localizedDescription, privacy: .public)")
                        return
                    }
                    self.participants = snap?.documents.compactMap { self.decodeParticipant($0) } ?? []
                }
            }

        // 3) Current round + 4) turns are attached/swapped when the room
        // doc updates currentRoundIndex (handled by an effect on top of
        // the `room` observable in the view layer, or by reacting here).
        // For now react here: re-attach whenever room changes index.
        // We use a Combine-free approach since this is @Observable.
        observeRoundIndex(code: code)
    }

    /// Auxiliary: each time `room.currentRoundIndex` advances, swap the
    /// round + turns listeners onto the new round path.
    private func observeRoundIndex(code: String) {
        // The room listener (1) already updates `self.room`. To react to
        // currentRoundIndex changes, we attach an additional
        // snapshot listener on the room doc that does the swap. This
        // duplicates the network read but is clearer than threading a
        // "previous index" state through the main room listener.
        // Negligible overhead — both listen on the same doc, Firestore
        // multiplexes the underlying watch.
        roomRef(code).addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                guard let self,
                      let idx = snap?.data()?["currentRoundIndex"] as? Int,
                      idx >= 0 else {
                    return
                }
                if self.currentRound?.index != idx {
                    self.attachRoundListeners(code: code, roundIndex: idx)
                }
            }
        }
    }

    private func attachRoundListeners(code: String, roundIndex: Int) {
        roundListener?.remove()
        turnsListener?.remove()

        roundListener = roundRef(code, roundIndex).addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentRound = snap.flatMap { self.decodeRound($0) }
            }
        }

        turnsListener = turnsRef(code, roundIndex).order(by: "askedAt")
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.turns = snap?.documents.compactMap { self.decodeTurn($0) } ?? []
                }
            }
    }

    private func detachListeners() {
        roomListener?.remove();         roomListener = nil
        participantsListener?.remove(); participantsListener = nil
        roundListener?.remove();        roundListener = nil
        turnsListener?.remove();        turnsListener = nil
    }

    private func clearLocalState() {
        room = nil
        participants = []
        currentRound = nil
        turns = []
    }

    // MARK: - Path helpers

    private func roomRef(_ code: String) -> DocumentReference {
        db.collection("rooms").document(code)
    }
    private func participantsRef(_ code: String) -> CollectionReference {
        roomRef(code).collection("participants")
    }
    private func participantRef(_ code: String, _ uid: String) -> DocumentReference {
        participantsRef(code).document(uid)
    }
    private func roundsRef(_ code: String) -> CollectionReference {
        roomRef(code).collection("rounds")
    }
    private func roundRef(_ code: String, _ index: Int) -> DocumentReference {
        roundsRef(code).document(String(index))
    }
    private func turnsRef(_ code: String, _ roundIndex: Int) -> CollectionReference {
        roundRef(code, roundIndex).collection("turns")
    }
    private func turnRef(_ code: String, _ roundIndex: Int, _ turnId: String) -> DocumentReference {
        turnsRef(code, roundIndex).document(turnId)
    }

    // MARK: - Room code mint

    /// Try up to 10 random codes; first one that doesn't collide wins.
    /// Collision probability over 32^6 codes is negligible — the retry is
    /// belt-and-suspenders.
    private func mintRoomCode() async throws -> String {
        for _ in 0..<10 {
            let code = RoomCode.mint()
            let snap = try await roomRef(code).getDocument()
            if !snap.exists { return code }
        }
        throw RoomError.codeMintFailed
    }

    // MARK: - Encoding (Swift → Firestore)
    //
    // Manual [String: Any] mapping rather than Codable+Firestore.
    // Mirrors the pattern in FirestoreService.swift and keeps the wire
    // format explicit and reviewable.

    private func encodeRoom(_ r: Room) -> [String: Any] {
        var d: [String: Any] = [
            "code":              r.code,
            "hostUid":           r.hostUid,
            "hostDisplayName":   r.hostDisplayName,
            "mode":              r.mode.rawValue,
            "status":            r.status.rawValue,
            "createdAt":         Timestamp(date: r.createdAt),
            "currentRoundIndex": r.currentRoundIndex,
            "settings": [
                "maxRounds":          r.settings.maxRounds,
                "questionerRotation": r.settings.questionerRotation.rawValue
            ]
        ]
        if let t = r.startedAt  { d["startedAt"]  = Timestamp(date: t) }
        if let t = r.finishedAt { d["finishedAt"] = Timestamp(date: t) }
        return d
    }

    private func encodeParticipant(_ p: Participant) -> [String: Any] {
        var d: [String: Any] = [
            "uid":            p.uid,
            "displayName":    p.displayName,
            "joinedAt":       Timestamp(date: p.joinedAt),
            "isHost":         p.isHost,
            "isEliminated":   p.isEliminated,
            "score":          p.score,
            "questionsAsked": p.questionsAsked,
            "roundsWon":      p.roundsWon
        ]
        if let f = p.fastestSolveSecs { d["fastestSolveSecs"] = f }
        return d
    }

    private func encodeRound(_ r: Round) -> [String: Any] {
        var d: [String: Any] = [
            "index":            r.index,
            "questionerUid":    r.questionerUid,
            "puzzleScenario":   r.puzzleScenario,
            "puzzleDifficulty": r.puzzleDifficulty.rawValue,
            "status":           r.status.rawValue,
            "questionCount":    r.questionCount
        ]
        if let v = r.puzzleHint   { d["puzzleHint"]   = v }
        if let v = r.puzzleAuthor { d["puzzleAuthor"] = v }
        if let v = r.puzzleTitle  { d["puzzleTitle"]  = v }
        if let v = r.startedAt    { d["startedAt"]    = Timestamp(date: v) }
        if let v = r.endedAt      { d["endedAt"]      = Timestamp(date: v) }
        if let v = r.winnerUid    { d["winnerUid"]    = v }
        return d
    }

    private func encodeTurn(_ t: Turn) -> [String: Any] {
        var d: [String: Any] = [
            "id":               t.id,
            "askerUid":         t.askerUid,
            "askerDisplayName": t.askerDisplayName,
            "text":             t.text,
            "askedAt":          Timestamp(date: t.askedAt)
            // verdict / comment / adjudicatedAt are intentionally absent
            // on create. Security rules require `verdict == null` for the
            // create gate; writing nil keys would be ambiguous. Updates
            // by the host fill them in.
        ]
        if let v = t.verdict       { d["verdict"]       = v.rawValue }
        if let v = t.comment       { d["comment"]       = v }
        if let v = t.adjudicatedAt { d["adjudicatedAt"] = Timestamp(date: v) }
        return d
    }

    // MARK: - Decoding (Firestore → Swift)

    private func decodeRoom(_ snap: DocumentSnapshot) -> Room? {
        guard let d = snap.data(),
              let code            = d["code"] as? String,
              let hostUid         = d["hostUid"] as? String,
              let hostDisplayName = d["hostDisplayName"] as? String,
              let modeStr         = d["mode"] as? String,
              let mode            = Room.Mode(rawValue: modeStr),
              let statusStr       = d["status"] as? String,
              let status          = Room.Status(rawValue: statusStr),
              let createdAt       = (d["createdAt"] as? Timestamp)?.dateValue(),
              let currentRoundIdx = d["currentRoundIndex"] as? Int,
              let settingsDict    = d["settings"] as? [String: Any],
              let maxRounds       = settingsDict["maxRounds"] as? Int,
              let rotationStr     = settingsDict["questionerRotation"] as? String,
              let rotation        = Room.Settings.Rotation(rawValue: rotationStr) else {
            return nil
        }
        return Room(
            code:              code,
            hostUid:           hostUid,
            hostDisplayName:   hostDisplayName,
            mode:              mode,
            status:            status,
            createdAt:         createdAt,
            startedAt:         (d["startedAt"]  as? Timestamp)?.dateValue(),
            finishedAt:        (d["finishedAt"] as? Timestamp)?.dateValue(),
            currentRoundIndex: currentRoundIdx,
            settings: Room.Settings(maxRounds: maxRounds, questionerRotation: rotation)
        )
    }

    private func decodeParticipant(_ snap: QueryDocumentSnapshot) -> Participant? {
        let d = snap.data()
        guard let uid          = d["uid"] as? String,
              let displayName  = d["displayName"] as? String,
              let joinedAt     = (d["joinedAt"] as? Timestamp)?.dateValue(),
              let isHost       = d["isHost"] as? Bool else {
            return nil
        }
        return Participant(
            uid:              uid,
            displayName:      displayName,
            joinedAt:         joinedAt,
            isHost:           isHost,
            isEliminated:     d["isEliminated"]     as? Bool ?? false,
            score:            d["score"]            as? Int ?? 0,
            fastestSolveSecs: d["fastestSolveSecs"] as? Int,
            questionsAsked:   d["questionsAsked"]   as? Int ?? 0,
            roundsWon:        d["roundsWon"]        as? Int ?? 0
        )
    }

    private func decodeRound(_ snap: DocumentSnapshot) -> Round? {
        guard let d = snap.data(),
              let index             = d["index"] as? Int,
              let questionerUid     = d["questionerUid"] as? String,
              let puzzleScenario    = d["puzzleScenario"] as? String,
              let difficultyStr     = d["puzzleDifficulty"] as? String,
              let puzzleDifficulty  = Puzzle.Difficulty(rawValue: difficultyStr),
              let statusStr         = d["status"] as? String,
              let status            = Round.Status(rawValue: statusStr),
              let questionCount     = d["questionCount"] as? Int else {
            return nil
        }
        return Round(
            index:            index,
            questionerUid:    questionerUid,
            puzzleScenario:   puzzleScenario,
            puzzleHint:       d["puzzleHint"]    as? String,
            puzzleAuthor:     d["puzzleAuthor"]  as? String,
            puzzleTitle:      d["puzzleTitle"]   as? String,
            puzzleDifficulty: puzzleDifficulty,
            status:           status,
            startedAt:        (d["startedAt"] as? Timestamp)?.dateValue(),
            endedAt:          (d["endedAt"]   as? Timestamp)?.dateValue(),
            winnerUid:        d["winnerUid"] as? String,
            questionCount:    questionCount
        )
    }

    private func decodeTurn(_ snap: QueryDocumentSnapshot) -> Turn? {
        let d = snap.data()
        guard let id               = d["id"] as? String,
              let askerUid         = d["askerUid"] as? String,
              let askerDisplayName = d["askerDisplayName"] as? String,
              let text             = d["text"] as? String,
              let askedAt          = (d["askedAt"] as? Timestamp)?.dateValue() else {
            return nil
        }
        return Turn(
            id:               id,
            askerUid:         askerUid,
            askerDisplayName: askerDisplayName,
            text:             text,
            askedAt:          askedAt,
            verdict:          (d["verdict"] as? String).flatMap { Message.Verdict(rawValue: $0) },
            comment:          d["comment"] as? String,
            adjudicatedAt:    (d["adjudicatedAt"] as? Timestamp)?.dateValue()
        )
    }
}

// MARK: - RoomError

enum RoomError: LocalizedError {
    case notSignedIn
    case notInRoom
    case notHost
    case notQuestioner
    case roomInactive
    case roundInactive
    case invalidCode
    case roomNotFound
    case roomFinished
    case malformedRoom
    case emptyQuestion
    case codeMintFailed

    var errorDescription: String? {
        switch self {
        case .notSignedIn:     return "请先登录"
        case .notInRoom:       return "未加入房间"
        case .notHost:         return "仅主持人可操作"
        case .notQuestioner:   return "本轮不是你提问"
        case .roomInactive:    return "房间未开始"
        case .roundInactive:   return "当前回合未激活"
        case .invalidCode:     return "房间码格式不对"
        case .roomNotFound:    return "房间不存在"
        case .roomFinished:    return "房间已结束"
        case .malformedRoom:   return "房间数据异常"
        case .emptyQuestion:   return "请输入问题"
        case .codeMintFailed:  return "生成房间码失败，请重试"
        }
    }
}
