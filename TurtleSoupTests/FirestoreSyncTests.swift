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
    /// Stubbed return value for fetchUserPuzzles
    var stubbedUserPuzzles: [Puzzle] = []

    func saveRecord(_ record: GameRecord, uid: String) async {
        savedRecords.append(record)
    }
    func fetchRecords(uid: String) async -> [GameRecord] {
        stubbedRecords
    }
    var aiReviewUpdates: [(UUID, GameReview)] = []
    func updateAIReview(recordID: UUID, review: GameReview, uid: String) async {
        aiReviewUpdates.append((recordID, review))
    }
    func savePuzzle(_ puzzle: Puzzle, uid: String) async {
        savedPuzzles.append(puzzle)
    }
    func deletePuzzle(id: UUID, uid: String) async {
        deletedPuzzleIDs.append(id)
    }
    func fetchUserPuzzles(uid: String) async -> [Puzzle] { stubbedUserPuzzles }
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

    func testSyncFromFirestoreMergesRemotePuzzles() async {
        let remote = makePuzzle(title: "Remote Puzzle")
        mock.stubbedUserPuzzles = [remote]
        await store.syncFromFirestore(uid: "uid_abc")
        XCTAssertTrue(store.puzzles.contains(where: { $0.id == remote.id }))
    }

    func testSyncFromFirestoreUpsertsByID() async {
        // Save a local puzzle, then pull a remote one with same ID but different title.
        // Remote should win (upsert by UUID).
        let id = UUID()
        let local  = Puzzle(id: id, title: "Local",  difficulty: .easy,
                            scenario: "s", answer: "a", hint: nil,
                            author: "me", playCount: 0)
        let remote = Puzzle(id: id, title: "Remote", difficulty: .medium,
                            scenario: "s2", answer: "a2", hint: "h",
                            author: "them", playCount: 0)
        store.save(local)
        mock.stubbedUserPuzzles = [remote]
        await store.syncFromFirestore(uid: "uid_abc")

        let matches = store.puzzles.filter { $0.id == id }
        XCTAssertEqual(matches.count, 1, "Should not duplicate on UUID match")
        XCTAssertEqual(matches.first?.title, "Remote")
        XCTAssertEqual(matches.first?.difficulty, .medium)
    }

    func testSyncFromFirestoreEmptyRemoteIsNoOp() async {
        let local = makePuzzle(title: "Local Only")
        store.save(local)
        mock.stubbedUserPuzzles = []
        await store.syncFromFirestore(uid: "uid_abc")
        XCTAssertTrue(store.puzzles.contains(where: { $0.id == local.id }))
    }

    // MARK: - Helpers

    private func makePuzzle(title: String = "题目") -> Puzzle {
        Puzzle(id: UUID(), title: title, difficulty: .easy,
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
