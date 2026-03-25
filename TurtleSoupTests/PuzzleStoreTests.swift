import XCTest
import CoreData
@testable import TurtleSoup

final class PuzzleStoreTests: XCTestCase {

    private var store: PuzzleStore!

    override func setUp() {
        super.setUp()
        clearAllPuzzles()
        store = PuzzleStore()
    }

    override func tearDown() {
        clearAllPuzzles()
        super.tearDown()
    }

    func testSaveNewPuzzle() {
        let p = makePuzzle(title: "测试题")
        store.save(p)
        XCTAssertEqual(store.puzzles.count, 1)
        XCTAssertEqual(store.puzzles[0].title, "测试题")
    }

    func testSaveUpdatesExisting() {
        var p = makePuzzle(title: "旧标题")
        store.save(p)
        p.title = "新标题"
        store.save(p)
        XCTAssertEqual(store.puzzles.count, 1)
        XCTAssertEqual(store.puzzles[0].title, "新标题")
    }

    func testDelete() {
        let p = makePuzzle(title: "删除我")
        store.save(p)
        store.delete(p)
        XCTAssertTrue(store.puzzles.isEmpty)
    }

    func testPersistence() {
        let p = makePuzzle(title: "持久化")
        store.save(p)
        let store2 = PuzzleStore()
        XCTAssertEqual(store2.puzzles.count, 1)
        XCTAssertEqual(store2.puzzles[0].title, "持久化")
    }

    // MARK: - Helper

    private func makePuzzle(title: String) -> Puzzle {
        Puzzle(id: UUID(), title: title, difficulty: .easy,
               scenario: "汤面", answer: "汤底", hint: nil,
               author: "测试", playCount: 0)
    }

    private func clearAllPuzzles() {
        let ctx = PersistenceController.shared.ctx
        let req = NSFetchRequest<NSManagedObject>(entityName: "UserPuzzleEntity")
        let all = (try? ctx.fetch(req)) ?? []
        all.forEach { ctx.delete($0) }
        PersistenceController.shared.save()
    }
}
