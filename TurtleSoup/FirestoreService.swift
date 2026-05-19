import Foundation
import FirebaseFirestore
import os.log

struct FirestoreService: FirestoreServicing {

    private let db = Firestore.firestore()
    private let logger = Logger(subsystem: "com.haiguitang", category: "Firestore")

    // MARK: - Path helpers

    private func userRef(_ uid: String) -> DocumentReference {
        db.collection("users").document(uid)
    }
    private func recordsRef(_ uid: String) -> CollectionReference {
        userRef(uid).collection("gameRecords")
    }
    private func puzzlesRef(_ uid: String) -> CollectionReference {
        userRef(uid).collection("puzzles")
    }
    private var publicPuzzlesRef: CollectionReference {
        db.collection("publicPuzzles")
    }

    // MARK: - Game Records

    func saveRecord(_ record: GameRecord, uid: String) async {
        var data: [String: Any] = [
            "id":            record.id.uuidString,
            "puzzleID":      record.puzzleID.uuidString,
            "puzzleTitle":   record.puzzleTitle,
            "startedAt":     Timestamp(date: record.startedAt),
            "endedAt":       Timestamp(date: record.endedAt),
            "isWon":         record.isWon,
            "questionCount": record.questionCount
        ]
        // Persist AI review as JSON string. Keeps schema flat — adding new
        // GameReview fields doesn't require a Firestore schema change.
        if let review = record.aiReview,
           let json = try? JSONEncoder().encode(review),
           let jsonStr = String(data: json, encoding: .utf8) {
            data["aiReview"] = jsonStr
        }
        // Persist transcript as a JSON blob too. Lets a second device see
        // what was asked/answered without us having to denormalize messages
        // into a sub-collection. 50-turn game ≈ 5KB — comfortably under the
        // 1MB document cap. Skip when empty (e.g. records pulled via
        // syncFromFirestore, which carry no messages).
        if !record.messages.isEmpty,
           let json = try? JSONEncoder().encode(record.messages),
           let jsonStr = String(data: json, encoding: .utf8) {
            data["messagesJSON"] = jsonStr
        }
        do {
            // Use record.id (UUID) as the document ID to avoid timeInterval precision collisions
            try await recordsRef(uid)
                .document(record.id.uuidString)
                .setData(data, merge: true)
        } catch {
            logger.error("Firestore saveRecord failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func updateAIReview(recordID: UUID, review: GameReview, uid: String) async {
        guard let json = try? JSONEncoder().encode(review),
              let jsonStr = String(data: json, encoding: .utf8) else {
            logger.error("Firestore updateAIReview: failed to encode review")
            return
        }
        do {
            try await recordsRef(uid)
                .document(recordID.uuidString)
                .setData(["aiReview": jsonStr], merge: true)
        } catch {
            logger.error("Firestore updateAIReview failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetch remote game records and parse them into `GameRecord` values.
    /// Returned records have empty `messages` (not stored in Firestore).
    func fetchRecords(uid: String) async -> [GameRecord] {
        do {
            let snapshot = try await recordsRef(uid).getDocuments()
            return snapshot.documents.compactMap { doc in
                let d = doc.data()
                guard
                    let idStr    = d["id"]            as? String, let id = UUID(uuidString: idStr),
                    let pidStr   = d["puzzleID"]       as? String, let puzzleID = UUID(uuidString: pidStr),
                    let title    = d["puzzleTitle"]    as? String,
                    let startTS  = d["startedAt"]      as? Timestamp,
                    let endTS    = d["endedAt"]        as? Timestamp,
                    let isWon    = d["isWon"]          as? Bool,
                    let qCount   = d["questionCount"]  as? Int
                else { return nil }
                // aiReview is optional; tolerate it being missing or malformed.
                var review: GameReview? = nil
                if let jsonStr = d["aiReview"] as? String,
                   let data = jsonStr.data(using: .utf8) {
                    review = try? JSONDecoder().decode(GameReview.self, from: data)
                }
                // messagesJSON: same shape as aiReview — missing or malformed
                // degrades to an empty transcript so the rest of the record
                // still loads. Empty array is a valid state (pre-N2 records).
                var messages: [Message] = []
                if let jsonStr = d["messagesJSON"] as? String,
                   let data = jsonStr.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([Message].self, from: data) {
                    messages = decoded
                }
                return GameRecord(
                    id:            id,
                    puzzleID:      puzzleID,
                    puzzleTitle:   title,
                    startedAt:     startTS.dateValue(),
                    endedAt:       endTS.dateValue(),
                    isWon:         isWon,
                    questionCount: qCount,
                    messages:      messages,
                    aiReview:      review
                )
            }
        } catch {
            logger.error("Firestore fetchRecords failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - User Puzzles

    func savePuzzle(_ puzzle: Puzzle, uid: String) async {
        var data: [String: Any] = [
            "id":         puzzle.id.uuidString,
            "title":      puzzle.title,
            "difficulty": puzzle.difficulty.rawValue,
            "scenario":   puzzle.scenario,
            "answer":     puzzle.answer,
            "author":     puzzle.author,
            "playCount":  puzzle.playCount
        ]
        if let hint = puzzle.hint { data["hint"] = hint }
        do {
            try await puzzlesRef(uid).document(puzzle.id.uuidString).setData(data, merge: true)
        } catch {
            logger.error("Firestore savePuzzle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deletePuzzle(id: UUID, uid: String) async {
        do {
            try await puzzlesRef(uid).document(id.uuidString).delete()
        } catch {
            logger.error("Firestore deletePuzzle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func fetchUserPuzzles(uid: String) async -> [Puzzle] {
        do {
            let snapshot = try await puzzlesRef(uid).getDocuments()
            return snapshot.documents.compactMap { doc in
                let d = doc.data()
                guard
                    let idStr    = d["id"]         as? String, let id = UUID(uuidString: idStr),
                    let title    = d["title"]       as? String,
                    let diffStr  = d["difficulty"]  as? String,
                    let diff     = Puzzle.Difficulty(rawValue: diffStr),
                    let scenario = d["scenario"]    as? String,
                    let answer   = d["answer"]      as? String,
                    let author   = d["author"]      as? String
                else { return nil }
                return Puzzle(
                    id: id, title: title, difficulty: diff,
                    scenario: scenario, answer: answer,
                    hint: d["hint"] as? String,
                    author: author,
                    playCount: d["playCount"] as? Int ?? 0
                )
            }
        } catch {
            logger.error("Firestore fetchUserPuzzles failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Public Puzzles

    func publishPuzzle(_ puzzle: Puzzle, uid: String) async {
        var data: [String: Any] = [
            "id":          puzzle.id.uuidString,
            "title":       puzzle.title,
            "difficulty":  puzzle.difficulty.rawValue,
            "scenario":    puzzle.scenario,
            "answer":      puzzle.answer,
            "author":      puzzle.author,
            "playCount":   puzzle.playCount,
            "authorUID":   uid,
            "publishedAt": FieldValue.serverTimestamp()
        ]
        if let hint = puzzle.hint { data["hint"] = hint }
        do {
            try await publicPuzzlesRef.document(puzzle.id.uuidString).setData(data, merge: true)
        } catch {
            logger.error("Firestore publishPuzzle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func fetchPublicPuzzles(limit: Int = 50) async -> [Puzzle] {
        do {
            let snapshot = try await publicPuzzlesRef
                .order(by: "publishedAt", descending: true)
                .limit(to: limit)
                .getDocuments()
            return snapshot.documents.compactMap { doc in
                let d = doc.data()
                guard
                    let idStr    = d["id"]         as? String, let id = UUID(uuidString: idStr),
                    let title    = d["title"]       as? String,
                    let diffStr  = d["difficulty"]  as? String,
                    let diff     = Puzzle.Difficulty(rawValue: diffStr),
                    let scenario = d["scenario"]    as? String,
                    let answer   = d["answer"]      as? String,
                    let author   = d["author"]      as? String
                else { return nil }
                return Puzzle(
                    id: id, title: title, difficulty: diff,
                    scenario: scenario, answer: answer,
                    hint: d["hint"] as? String,
                    author: author,
                    playCount: d["playCount"] as? Int ?? 0
                )
            }
        } catch {
            logger.error("Firestore fetchPublicPuzzles failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Increment publicPuzzles/{id}.playCount by 1. Uses FieldValue.increment
    /// so concurrent plays from different devices don't race. Silently no-ops
    /// if the doc doesn't exist (built-in puzzle ID, or user's own
    /// unpublished puzzle) — we don't want to materialize a phantom public
    /// puzzle row, and security rules would reject it anyway.
    func incrementPublicPlayCount(puzzleID: UUID) async {
        let ref = publicPuzzlesRef.document(puzzleID.uuidString)
        do {
            let snapshot = try await ref.getDocument()
            guard snapshot.exists else { return }
            try await ref.updateData(["playCount": FieldValue.increment(Int64(1))])
        } catch {
            logger.error("Firestore incrementPublicPlayCount failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
