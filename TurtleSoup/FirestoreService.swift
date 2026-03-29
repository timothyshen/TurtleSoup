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
        let data: [String: Any] = [
            "id":            record.id.uuidString,
            "puzzleID":      record.puzzleID.uuidString,
            "puzzleTitle":   record.puzzleTitle,
            "startedAt":     Timestamp(date: record.startedAt),
            "endedAt":       Timestamp(date: record.endedAt),
            "isWon":         record.isWon,
            "questionCount": record.questionCount
        ]
        do {
            // Use record.id (UUID) as the document ID to avoid timeInterval precision collisions
            try await recordsRef(uid)
                .document(record.id.uuidString)
                .setData(data, merge: true)
        } catch {
            logger.error("Firestore saveRecord failed: \(error.localizedDescription, privacy: .public)")
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
                return GameRecord(
                    id:            id,
                    puzzleID:      puzzleID,
                    puzzleTitle:   title,
                    startedAt:     startTS.dateValue(),
                    endedAt:       endTS.dateValue(),
                    isWon:         isWon,
                    questionCount: qCount,
                    messages:      []
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

    func fetchUserPuzzles(uid: String) async -> [[String: Any]] {
        do {
            let snapshot = try await puzzlesRef(uid).getDocuments()
            return snapshot.documents.map { $0.data() }
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
}
