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

    init(id: UUID = UUID(),
         puzzleID: UUID, puzzleTitle: String,
         startedAt: Date, endedAt: Date,
         isWon: Bool, questionCount: Int,
         messages: [Message]) {
        self.id            = id
        self.puzzleID      = puzzleID
        self.puzzleTitle   = puzzleTitle
        self.startedAt     = startedAt
        self.endedAt       = endedAt
        self.isWon         = isWon
        self.questionCount = questionCount
        self.messages      = messages
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

        // Dedup: skip if same puzzleID + startedAt already exists
        let dup = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        dup.predicate = NSPredicate(format: "puzzleID == %@ AND startedAt == %@",
                                    record.puzzleID as CVarArg,
                                    record.startedAt as NSDate)
        dup.fetchLimit = 1
        if let existing = try? ctx.fetch(dup), !existing.isEmpty { return }

        let recObj = NSEntityDescription.insertNewObject(
            forEntityName: "GameRecordEntity", into: ctx)
        recObj.setValue(UUID(),                          forKey: "id")
        recObj.setValue(record.puzzleID,                 forKey: "puzzleID")
        recObj.setValue(record.puzzleTitle,              forKey: "puzzleTitle")
        recObj.setValue(record.startedAt,                forKey: "startedAt")
        recObj.setValue(record.endedAt,                  forKey: "endedAt")
        recObj.setValue(record.isWon,                    forKey: "isWon")
        recObj.setValue(Int32(record.questionCount),     forKey: "questionCount")

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

    // MARK: - Remote Sync

    /// Pull game records from Firestore and merge into local CoreData.
    /// Messages are not stored in Firestore; synced records will have empty message history.
    func syncFromFirestore(uid: String) async {
        let remote = await firestore.fetchRecords(uid: uid)
        for record in remote {
            saveRecord(record)   // dedup by puzzleID + startedAt is handled inside saveRecord
        }
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
