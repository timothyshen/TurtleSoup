import XCTest
import CoreData
@testable import TurtleSoup

// MARK: - Mock

final class MockFirestoreService: FirestoreServicing {

    var savedRecords:      [GameRecord] = []
    var savedPuzzles:      [Puzzle]     = []
    var deletedPuzzleIDs:  [UUID]       = []
    var publishedPuzzles:  [Puzzle]     = []

    /// Stubbed return value for fetchRecords
    var stubbedRecords: [GameRecord] = []

    func saveRecord(_ record: GameRecord, uid: String) async {
        savedRecords.append(record)
    }
    func fetchRecords(uid: String) async -> [GameRecord] {
        stubbedRecords
    }
    func savePuzzle(_ puzzle: Puzzle, uid: String) async {
        savedPuzzles.append(puzzle)
    }
    func deletePuzzle(id: UUID, uid: String) async {
        deletedPuzzleIDs.append(id)
    }
    func fetchUserPuzzles(uid: String) async -> [[String: Any]] { [] }
    func publishPuzzle(_ puzzle: Puzzle, uid: String) async {
        publishedPuzzles.append(puzzle)
    }
    func fetchPublicPuzzles(limit: Int) async -> [Puzzle] { [] }
}

// MARK: - GameRecordStore Sync Tests

@MainActor
final class GameRecordStoreSyncTests: XCTestCase {

    private var mock: MockFirestoreService!
    private var store: GameRecordStore!

    override func setUp() {
        super.setUp()
        mock  = MockFirestoreService()
        store = GameRecordStore(pc: .test, firestore: mock)
        clearRecords()
    }

    override func tearDown() {
        clearRecords()
        store = nil
        mock  = nil
        super.tearDown()
    }

    func testSaveRecordSyncsToFirestoreWhenSignedIn() async throws {
        store.currentUID = "uid_abc"
        store.saveRecord(makeRecord())
        // Yield to let the detached Task complete
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mock.savedRecords.count, 1)
    }

    func testSaveRecordDoesNotSyncWhenSignedOut() async throws {
        // currentUID is nil by default
        store.saveRecord(makeRecord())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mock.savedRecords.count, 0)
    }

    func testSyncFromFirestoreMergesRemoteRecords() async {
        let remote = makeRecord(puzzleTitle: "Remote Puzzle")
        mock.stubbedRecords = [remote]
        await store.syncFromFirestore(uid: "uid_abc")
        XCTAssertEqual(store.playCount(for: remote.puzzleID), 1)
    }

    func testSyncFromFirestoreSkipsDuplicates() async {
        let record = makeRecord()
        store.saveRecord(record)
        mock.stubbedRecords = [record]   // same puzzleID + startedAt
        let countBefore = store.playCount(for: record.puzzleID)
        await store.syncFromFirestore(uid: "uid_abc")
        XCTAssertEqual(store.playCount(for: record.puzzleID), countBefore)  // no duplicate
    }

    // MARK: - Helpers

    private func makeRecord(puzzleTitle: String = "Test") -> GameRecord {
        GameRecord(
            id: UUID(),
            puzzleID: UUID(),
            puzzleTitle: puzzleTitle,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt:   Date(timeIntervalSince1970: 1_001_000),
            isWon: true,
            questionCount: 5,
            messages: []
        )
    }

    private func clearRecords() {
        let ctx = PersistenceController.test.ctx
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        ((try? ctx.fetch(req)) ?? []).forEach { ctx.delete($0) }
        PersistenceController.test.save()
    }
}

// MARK: - PuzzleStore Sync Tests

@MainActor
final class PuzzleStoreSyncTests: XCTestCase {

    private var mock: MockFirestoreService!
    private var store: PuzzleStore!

    override func setUp() {
        super.setUp()
        mock  = MockFirestoreService()
        store = PuzzleStore(pc: .test, firestore: mock)
        clearPuzzles()
    }

    override func tearDown() {
        clearPuzzles()
        store = nil
        mock  = nil
        super.tearDown()
    }

    func testSavePuzzleSyncsToFirestoreWhenSignedIn() async throws {
        store.currentUID = "uid_abc"
        store.save(makePuzzle())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mock.savedPuzzles.count, 1)
    }

    func testSavePuzzleDoesNotSyncWhenSignedOut() async throws {
        store.save(makePuzzle())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mock.savedPuzzles.count, 0)
    }

    func testDeletePuzzleSyncsToFirestoreWhenSignedIn() async throws {
        store.currentUID = "uid_abc"
        let p = makePuzzle()
        store.save(p)
        store.delete(p)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mock.deletedPuzzleIDs.first, p.id)
    }

    func testDeletePuzzleDoesNotSyncWhenSignedOut() async throws {
        let p = makePuzzle()
        store.save(p)
        store.delete(p)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(mock.deletedPuzzleIDs.isEmpty)
    }

    // MARK: - Helpers

    private func makePuzzle() -> Puzzle {
        Puzzle(id: UUID(), title: "题目", difficulty: .easy,
               scenario: "汤面", answer: "汤底", hint: nil,
               author: "测试", playCount: 0)
    }

    private func clearPuzzles() {
        let ctx = PersistenceController.test.ctx
        let req = NSFetchRequest<NSManagedObject>(entityName: "UserPuzzleEntity")
        ((try? ctx.fetch(req)) ?? []).forEach { ctx.delete($0) }
        PersistenceController.test.save()
    }
}
