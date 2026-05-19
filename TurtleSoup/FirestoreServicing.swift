import Foundation

/// Protocol for Firestore operations, allowing injection of mocks in tests.
///
/// `nonisolated` so this protocol — and any type that conforms to it —
/// isn't forced onto the MainActor by the project's -default-isolation
/// build setting. Callers include `actor` types (PuzzleGenerationService,
/// ReviewService) which can't talk to MainActor-bound APIs synchronously.
nonisolated protocol FirestoreServicing {
    func saveRecord(_ record: GameRecord, uid: String) async
    func fetchRecords(uid: String) async -> [GameRecord]
    func updateAIReview(recordID: UUID, review: GameReview, uid: String) async
    func savePuzzle(_ puzzle: Puzzle, uid: String) async
    func deletePuzzle(id: UUID, uid: String) async
    func fetchUserPuzzles(uid: String) async -> [Puzzle]
    func publishPuzzle(_ puzzle: Puzzle, uid: String) async
    func fetchPublicPuzzles(limit: Int) async -> [Puzzle]
    func incrementPublicPlayCount(puzzleID: UUID) async
}
