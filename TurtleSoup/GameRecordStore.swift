import CoreData
import Observation

/// Snapshot of one complete game session, used for persistence.
struct GameRecord {
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
    }

    // MARK: - Write

    func saveRecord(_ record: GameRecord) {
        let ctx = pc.ctx

        // Dedup: skip if same puzzleID + startedAt already exists.
        // On hit, backfill aiReview from the remote/incoming record if the
        // existing row doesn't have one — fixes the sync case where the
        // record was created locally, then the player generated a review on
        // another device, and we're now pulling it back.
        let dup = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        dup.predicate = NSPredicate(format: "puzzleID == %@ AND startedAt == %@",
                                    record.puzzleID as CVarArg,
                                    record.startedAt as NSDate)
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

    func records(for puzzleID: UUID) -> [NSManagedObject] {
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.predicate = NSPredicate(format: "puzzleID == %@", puzzleID as CVarArg)
        req.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        return (try? pc.ctx.fetch(req)) ?? []
    }
}
