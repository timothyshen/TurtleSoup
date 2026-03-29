/// Protocol for Firestore operations, allowing injection of mocks in tests.
protocol FirestoreServicing {
    func saveRecord(_ record: GameRecord, uid: String) async
    func fetchRecords(uid: String) async -> [GameRecord]
    func savePuzzle(_ puzzle: Puzzle, uid: String) async
    func deletePuzzle(id: UUID, uid: String) async
    func fetchUserPuzzles(uid: String) async -> [[String: Any]]
    func publishPuzzle(_ puzzle: Puzzle, uid: String) async
    func fetchPublicPuzzles(limit: Int) async -> [Puzzle]
}
