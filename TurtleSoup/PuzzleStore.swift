import Foundation
import CoreData
import Observation

@Observable
final class PuzzleStore {

    private(set) var puzzles: [Puzzle] = []
    private let pc = PersistenceController.shared

    init() {
        migrateFromUserDefaultsIfNeeded()
        fetch()
    }

    // MARK: - Public API

    func save(_ puzzle: Puzzle) {
        let obj = findOrCreate(id: puzzle.id)
        fill(obj, from: puzzle)
        pc.save()
        fetch()
    }

    func delete(_ puzzle: Puzzle) {
        let req = NSFetchRequest<NSManagedObject>(entityName: "UserPuzzleEntity")
        req.predicate = NSPredicate(format: "id == %@", puzzle.id as CVarArg)
        req.fetchLimit = 1
        if let found = try? pc.ctx.fetch(req).first {
            pc.ctx.delete(found)
            pc.save()
        }
        fetch()
    }

    // MARK: - Private

    private func fetch() {
        let req = NSFetchRequest<NSManagedObject>(entityName: "UserPuzzleEntity")
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let objects = (try? pc.ctx.fetch(req)) ?? []
        puzzles = objects.compactMap { toPuzzle($0) }
    }

    private func findOrCreate(id: UUID) -> NSManagedObject {
        let req = NSFetchRequest<NSManagedObject>(entityName: "UserPuzzleEntity")
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        if let found = try? pc.ctx.fetch(req).first { return found }
        let obj = NSEntityDescription.insertNewObject(forEntityName: "UserPuzzleEntity", into: pc.ctx)
        obj.setValue(id, forKey: "id")
        obj.setValue(Date(), forKey: "createdAt")
        return obj
    }

    private func fill(_ obj: NSManagedObject, from p: Puzzle) {
        obj.setValue(p.title,               forKey: "title")
        obj.setValue(p.difficulty.rawValue, forKey: "difficulty")
        obj.setValue(p.scenario,            forKey: "scenario")
        obj.setValue(p.answer,              forKey: "answer")
        obj.setValue(p.hint,                forKey: "hint")
        obj.setValue(p.author,              forKey: "author")
    }

    private func toPuzzle(_ obj: NSManagedObject) -> Puzzle? {
        guard
            let id       = obj.value(forKey: "id")         as? UUID,
            let title    = obj.value(forKey: "title")      as? String,
            let diffStr  = obj.value(forKey: "difficulty") as? String,
            let diff     = Puzzle.Difficulty(rawValue: diffStr),
            let scenario = obj.value(forKey: "scenario")   as? String,
            let answer   = obj.value(forKey: "answer")     as? String,
            let author   = obj.value(forKey: "author")     as? String
        else { return nil }
        let hint = obj.value(forKey: "hint") as? String
        return Puzzle(id: id, title: title, difficulty: diff,
                      scenario: scenario, answer: answer,
                      hint: hint, author: author, playCount: 0)
    }

    // MARK: - UserDefaults → CoreData one-time migration

    private func migrateFromUserDefaultsIfNeeded() {
        let migratedKey = "puzzle_store_coredata_migrated"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }

        if let data = UserDefaults.standard.data(forKey: "user_puzzles"),
           let old = try? JSONDecoder().decode([Puzzle].self, from: data) {
            for p in old {
                let obj = NSEntityDescription.insertNewObject(
                    forEntityName: "UserPuzzleEntity", into: pc.ctx)
                obj.setValue(p.id,                  forKey: "id")
                obj.setValue(p.title,               forKey: "title")
                obj.setValue(p.difficulty.rawValue, forKey: "difficulty")
                obj.setValue(p.scenario,            forKey: "scenario")
                obj.setValue(p.answer,              forKey: "answer")
                obj.setValue(p.hint,                forKey: "hint")
                obj.setValue(p.author,              forKey: "author")
                obj.setValue(Date(),                forKey: "createdAt")
            }
            pc.save()
            UserDefaults.standard.removeObject(forKey: "user_puzzles")
        }
        UserDefaults.standard.set(true, forKey: migratedKey)
    }
}
