import Observation

@Observable
@MainActor
final class PublicPuzzleStore {

    private(set) var puzzles: [Puzzle] = []
    private(set) var isLoading = false
    private let firestore = FirestoreService()

    func fetchIfNeeded() async {
        guard puzzles.isEmpty else { return }
        isLoading = true
        puzzles = await firestore.fetchPublicPuzzles()
        isLoading = false
    }

    func publish(_ puzzle: Puzzle, uid: String) async {
        await firestore.publishPuzzle(puzzle, uid: uid)
        // Optimistic insert at top
        if !puzzles.contains(where: { $0.id == puzzle.id }) {
            puzzles.insert(puzzle, at: 0)
        }
    }
}
