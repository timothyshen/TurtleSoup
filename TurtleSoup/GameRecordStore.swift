import CoreData
import Observation

/// Snapshot of one complete game session, used for persistence.
///
/// `nonisolated` because this is a plain Sendable value type — all fields
/// are value types or Sendable Codable structs. The project's
/// `-default-isolation=MainActor` flag would otherwise mark its memberwise
/// init as @MainActor-isolated, breaking calls from nonisolated contexts
/// like FirestoreService.fetchRecords (which builds GameRecord in a
/// background async task).
nonisolated struct GameRecord: Identifiable, Hashable {

    static func == (lhs: GameRecord, rhs: GameRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }


    let id: UUID
    let puzzleID: UUID
    let puzzleTitle: String
    let startedAt: Date
    let endedAt: Date
    let isWon: Bool
    let questionCount: Int
    let messages: [Message]
    /// AI-generated post-game review. nil until the player taps "生成 AI 复盘"
    /// and the proxy call returns. Cached locally so it isn't regenerated.
    var aiReview: GameReview?

    init(id: UUID = UUID(),
         puzzleID: UUID, puzzleTitle: String,
         startedAt: Date, endedAt: Date,
         isWon: Bool, questionCount: Int,
         messages: [Message],
         aiReview: GameReview? = nil) {
        self.id            = id
        self.puzzleID      = puzzleID
        self.puzzleTitle   = puzzleTitle
        self.startedAt     = startedAt
        self.endedAt       = endedAt
        self.isWon         = isWon
        self.questionCount = questionCount
        self.messages      = messages
        self.aiReview      = aiReview
    }
}

@Observable
@MainActor
final class GameRecordStore {

    private let pc: PersistenceController
    private let firestore: any FirestoreServicing
    /// Set by RootView when Firebase auth state changes.
    var currentUID: String? = nil
    private(set) var savedRecordCount: Int = 0

    init(pc: PersistenceController = .shared, firestore: any FirestoreServicing = FirestoreService()) {
        self.pc = pc
        self.firestore = firestore
        // One-shot dedup pass on launch. Cleans up the legacy duplicates
        // caused by the puzzleID+startedAt dedup predicate missing on
        // Firestore round-trip (Timestamp→Date sub-ms precision loss).
        // Idempotent — re-runs on every launch are cheap since the second
        // pass finds nothing to delete.
        deduplicateExistingRecords()
    }

    /// Walk every GameRecordEntity row, group by `id`, keep the first,
    /// delete the rest. Then group by `(puzzleID, startedAt-to-millisecond)`,
    /// same deal — catches the legacy case where two rows share metadata
    /// but have different ids (each came from a separate save).
    ///
    /// Runs synchronously in init since the dataset is small (typical user
    /// has < 100 game records) and we want the UI's first read of
    /// allRecords() to see the cleaned state.
    private func deduplicateExistingRecords() {
        let ctx = pc.ctx
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        guard let rows = try? ctx.fetch(req), !rows.isEmpty else { return }

        var seenIDs = Set<UUID>()
        var seenKeys = Set<String>()    // "puzzleID|epochSeconds"
        var toDelete: [NSManagedObject] = []

        for row in rows {
            // ID dedup
            if let id = row.value(forKey: "id") as? UUID {
                if seenIDs.contains(id) {
                    toDelete.append(row)
                    continue
                }
                seenIDs.insert(id)
            }
            // Metadata dedup (legacy rows that lacked id-based dedup at
            // save time). Round timestamp to seconds to absorb the
            // sub-millisecond drift that caused the original bug.
            if let pid = row.value(forKey: "puzzleID") as? UUID,
               let started = row.value(forKey: "startedAt") as? Date {
                let key = "\(pid.uuidString)|\(Int(started.timeIntervalSince1970))"
                if seenKeys.contains(key) {
                    toDelete.append(row)
                    continue
                }
                seenKeys.insert(key)
            }
        }

        if toDelete.isEmpty { return }
        for row in toDelete { ctx.delete(row) }
        pc.save()
    }

    // MARK: - Write

    func saveRecord(_ record: GameRecord) {
        let ctx = pc.ctx

        // Dedup: primary key is `record.id` (UUID). Previously this used
        // `puzzleID + startedAt`, which broke on cross-device sync —
        // Firestore Timestamp→Date round-trip drops sub-millisecond
        // precision, so the local `startedAt` and the synced-back one
        // don't compare equal, and the same record got written twice.
        // record.id is preserved verbatim through Firestore (the doc ID
        // == record.id.uuidString), so id-based dedup is bulletproof.
        //
        // Fallback: also check puzzleID + startedAt for legacy records
        // written before id dedup existed (those exist but rare; they'd
        // never get backfilled otherwise).
        //
        // On hit, backfill aiReview from the incoming record if the
        // existing row doesn't have one, and backfill transcript too.
        let dup = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        dup.predicate = NSPredicate(
            format: "id == %@ OR (puzzleID == %@ AND startedAt == %@)",
            record.id as CVarArg,
            record.puzzleID as CVarArg,
            record.startedAt as NSDate
        )
        dup.fetchLimit = 1
        if let existing = try? ctx.fetch(dup), let existingObj = existing.first {
            var didUpdate = false
            if existingObj.value(forKey: "aiReview") == nil,
               let incoming = Self.encodeReview(record.aiReview) {
                existingObj.setValue(incoming, forKey: "aiReview")
                didUpdate = true
            }
            // Backfill transcript from remote when local row has none. Covers
            // the cross-device sync case: device B fetched the record before
            // we started storing messagesJSON in Firestore, so its local row
            // is metadata-only. Now the remote carries messages — copy them in.
            let existingMessages = existingObj.value(forKey: "messages") as? Set<NSManagedObject>
            if (existingMessages?.isEmpty ?? true) && !record.messages.isEmpty {
                var msgSet = Set<NSManagedObject>()
                for msg in record.messages {
                    let msgObj = NSEntityDescription.insertNewObject(
                        forEntityName: "GameMessageEntity", into: ctx)
                    msgObj.setValue(msg.id,                forKey: "id")
                    msgObj.setValue(msg.role.rawValue,     forKey: "role")
                    msgObj.setValue(msg.text,              forKey: "text")
                    msgObj.setValue(msg.verdict?.rawValue, forKey: "verdict")
                    msgObj.setValue(msg.timestamp,         forKey: "timestamp")
                    msgObj.setValue(existingObj,           forKey: "record")
                    msgSet.insert(msgObj)
                }
                existingObj.setValue(msgSet, forKey: "messages")
                didUpdate = true
            }
            if didUpdate {
                pc.save()
                savedRecordCount += 1
            }
            return
        }

        let recObj = NSEntityDescription.insertNewObject(
            forEntityName: "GameRecordEntity", into: ctx)
        // Use record.id verbatim — the caller (GameViewModel) holds this id
        // and uses it later to attach an AI review via updateAIReview(recordID:).
        // Generating a fresh UUID here would silently desync the two.
        recObj.setValue(record.id,                       forKey: "id")
        recObj.setValue(record.puzzleID,                 forKey: "puzzleID")
        recObj.setValue(record.puzzleTitle,              forKey: "puzzleTitle")
        recObj.setValue(record.startedAt,                forKey: "startedAt")
        recObj.setValue(record.endedAt,                  forKey: "endedAt")
        recObj.setValue(record.isWon,                    forKey: "isWon")
        recObj.setValue(Int32(record.questionCount),     forKey: "questionCount")
        recObj.setValue(Self.encodeReview(record.aiReview), forKey: "aiReview")

        var msgSet = Set<NSManagedObject>()
        for msg in record.messages {
            let msgObj = NSEntityDescription.insertNewObject(
                forEntityName: "GameMessageEntity", into: ctx)
            msgObj.setValue(msg.id,               forKey: "id")
            msgObj.setValue(msg.role.rawValue,    forKey: "role")
            msgObj.setValue(msg.text,             forKey: "text")
            msgObj.setValue(msg.verdict?.rawValue,forKey: "verdict")
            msgObj.setValue(msg.timestamp,        forKey: "timestamp")
            msgObj.setValue(recObj,               forKey: "record")
            msgSet.insert(msgObj)
        }
        recObj.setValue(msgSet, forKey: "messages")

        savedRecordCount += 1
        pc.save()

        // Sync to Firestore if signed in
        if let uid = currentUID {
            Task { await firestore.saveRecord(record, uid: uid) }
        }
    }

    /// Increment the public-square playCount for a puzzle. Fire-and-forget;
    /// no-op if the puzzle isn't in publicPuzzles (handled server-side).
    /// Called by GameViewModel on win/giveUp when isPublicPuzzle is true.
    func incrementPublicPlayCount(puzzleID: UUID) {
        Task { await firestore.incrementPublicPlayCount(puzzleID: puzzleID) }
    }

    // MARK: - Remote Sync

    /// Pull game records from Firestore and merge into local CoreData.
    /// Messages are not stored in Firestore; synced records will have empty message history.
    func syncFromFirestore(uid: String) async {
        let remote = await firestore.fetchRecords(uid: uid)
        for record in remote {
            saveRecord(record)   // dedup by puzzleID + startedAt is handled inside saveRecord
        }
    }

    // MARK: - AI Review

    /// Persist an AI-generated review onto an existing record. Writes through
    /// to Firestore if signed in. Idempotent — calling twice with the same
    /// review is a no-op beyond the second write.
    func updateAIReview(recordID: UUID, review: GameReview) {
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.predicate = NSPredicate(format: "id == %@", recordID as CVarArg)
        req.fetchLimit = 1
        guard let recObj = try? pc.ctx.fetch(req).first else { return }
        recObj.setValue(Self.encodeReview(review), forKey: "aiReview")
        pc.save()
        savedRecordCount += 1   // trigger SwiftUI refresh

        if let uid = currentUID {
            Task { await firestore.updateAIReview(recordID: recordID, review: review, uid: uid) }
        }
    }

    /// Read the AI review (if any) from a fetched managed object.
    static func decodeReview(_ obj: NSManagedObject) -> GameReview? {
        guard let raw = obj.value(forKey: "aiReview") as? String,
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GameReview.self, from: data)
    }

    /// Most recent AI review for this puzzle across all past games, if any.
    /// Used by the answer sheet to surface a cached "上次复盘" when the
    /// current game hasn't generated one yet — saves a paid round trip
    /// when the player has already seen a review of the same puzzle.
    /// Returns nil if no record exists or none of them have a review.
    func latestReview(for puzzleID: UUID) -> GameReview? {
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.predicate = NSPredicate(format: "puzzleID == %@ AND aiReview != nil",
                                    puzzleID as CVarArg)
        req.sortDescriptors = [NSSortDescriptor(key: "endedAt", ascending: false)]
        req.fetchLimit = 1
        guard let obj = try? pc.ctx.fetch(req).first else { return nil }
        return Self.decodeReview(obj)
    }

    /// Fetch the transcript for a saved record, sorted chronologically.
    /// Returns an empty array if the record doesn't exist or has no messages.
    /// Reads the GameMessageEntity rows that saveRecord wrote (or backfilled
    /// from Firestore via messagesJSON on sync).
    func messages(for recordID: UUID) -> [Message] {
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.predicate = NSPredicate(format: "id == %@", recordID as CVarArg)
        req.fetchLimit = 1
        guard let recObj = try? pc.ctx.fetch(req).first,
              let set = recObj.value(forKey: "messages") as? Set<NSManagedObject>
        else { return [] }

        return set.compactMap { obj -> Message? in
            guard let roleRaw = obj.value(forKey: "role") as? String,
                  let role    = Message.Role(rawValue: roleRaw),
                  let text    = obj.value(forKey: "text") as? String,
                  let id      = obj.value(forKey: "id") as? UUID,
                  let ts      = obj.value(forKey: "timestamp") as? Date
            else { return nil }
            let verdict = (obj.value(forKey: "verdict") as? String)
                .flatMap(Message.Verdict.init(rawValue:))
            return Message(id: id, role: role, text: text, verdict: verdict, timestamp: ts)
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    /// Convenience for lookups by record id — used by GameView's answer sheet
    /// to render an existing review without re-fetching the full record.
    func review(for recordID: UUID) -> GameReview? {
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.predicate = NSPredicate(format: "id == %@", recordID as CVarArg)
        req.fetchLimit = 1
        guard let obj = try? pc.ctx.fetch(req).first else { return nil }
        return Self.decodeReview(obj)
    }

    // MARK: - Private helpers

    private static func encodeReview(_ review: GameReview?) -> String? {
        guard let review,
              let data = try? JSONEncoder().encode(review),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    // MARK: - Read / Stats

    func playCount(for puzzleID: UUID) -> Int {
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.predicate = NSPredicate(format: "puzzleID == %@", puzzleID as CVarArg)
        return (try? pc.ctx.count(for: req)) ?? 0
    }

    func winRate(for puzzleID: UUID) -> Double {
        let total = playCount(for: puzzleID)
        guard total > 0 else { return 0 }
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.predicate = NSPredicate(format: "puzzleID == %@ AND isWon == YES",
                                    puzzleID as CVarArg)
        let wins = (try? pc.ctx.count(for: req)) ?? 0
        return Double(wins) / Double(total)
    }

    /// Fetch every game record, fully hydrated (transcript + AI review),
    /// sorted by start time descending. Drives the history viewer.
    func allRecords() -> [GameRecord] {
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        guard let objs = try? pc.ctx.fetch(req) else { return [] }
        return objs.compactMap { hydrate($0) }
    }

    private func hydrate(_ obj: NSManagedObject) -> GameRecord? {
        guard
            let id            = obj.value(forKey: "id")            as? UUID,
            let puzzleID      = obj.value(forKey: "puzzleID")      as? UUID,
            let puzzleTitle   = obj.value(forKey: "puzzleTitle")   as? String,
            let startedAt     = obj.value(forKey: "startedAt")     as? Date,
            let endedAt       = obj.value(forKey: "endedAt")       as? Date,
            let isWon         = obj.value(forKey: "isWon")         as? Bool,
            let questionCount = obj.value(forKey: "questionCount") as? Int32
        else { return nil }

        let msgs = (obj.value(forKey: "messages") as? Set<NSManagedObject>)?
            .compactMap { msg -> Message? in
                guard
                    let mid     = msg.value(forKey: "id")        as? UUID,
                    let roleRaw = msg.value(forKey: "role")      as? String,
                    let role    = Message.Role(rawValue: roleRaw),
                    let text    = msg.value(forKey: "text")      as? String,
                    let ts      = msg.value(forKey: "timestamp") as? Date
                else { return nil }
                let verdict = (msg.value(forKey: "verdict") as? String)
                    .flatMap(Message.Verdict.init(rawValue:))
                return Message(id: mid, role: role, text: text, verdict: verdict, timestamp: ts)
            }
            .sorted { $0.timestamp < $1.timestamp } ?? []

        return GameRecord(
            id:            id,
            puzzleID:      puzzleID,
            puzzleTitle:   puzzleTitle,
            startedAt:     startedAt,
            endedAt:       endedAt,
            isWon:         isWon,
            questionCount: Int(questionCount),
            messages:      msgs,
            aiReview:      Self.decodeReview(obj)
        )
    }

    func records(for puzzleID: UUID) -> [NSManagedObject] {
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.predicate = NSPredicate(format: "puzzleID == %@", puzzleID as CVarArg)
        req.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        return (try? pc.ctx.fetch(req)) ?? []
    }
}
