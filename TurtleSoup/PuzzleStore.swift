import Foundation
import Observation

@Observable
final class PuzzleStore {

    private(set) var puzzles: [Puzzle] = []
    private let key: String

    init(key: String = "user_puzzles") {
        self.key = key
        load()
    }

    func save(_ puzzle: Puzzle) {
        if let i = puzzles.firstIndex(where: { $0.id == puzzle.id }) {
            puzzles[i] = puzzle
        } else {
            puzzles.append(puzzle)
        }
        persist()
    }

    func delete(_ puzzle: Puzzle) {
        puzzles.removeAll { $0.id == puzzle.id }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Puzzle].self, from: data)
        else { return }
        puzzles = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(puzzles) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
