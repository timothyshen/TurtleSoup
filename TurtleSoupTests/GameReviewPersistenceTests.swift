import XCTest
import CoreData
@testable import TurtleSoup

/// Belt-and-suspenders coverage for the AI-review persistence path.
///
/// Two parties have to agree on the on-disk shape:
///   1. JSONEncoder/Decoder against the GameReview struct (used both for
///      the Firestore string field and the CoreData "aiReview" attribute).
///   2. GameRecordStore: writes the encoded blob on saveRecord /
///      updateAIReview, reads it back on review(for:).
///
/// If either side drifts (renamed key, missing CodingKey, lost optionality)
/// reviews silently round-trip as nil. These tests fail loudly instead.
@MainActor
final class GameReviewPersistenceTests: XCTestCase {

    private var store: GameRecordStore!

    override func setUp() {
        super.setUp()
        store = GameRecordStore(pc: .test, firestore: MockFirestoreService())
        clearRecords()
    }

    override func tearDown() {
        clearRecords()
        store = nil
        super.tearDown()
    }

    // MARK: - JSON round-trip

    func testJSONEncodeDecodeRoundTripIsIdentity() throws {
        let original = makeReview()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GameReview.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testWireFormatUsesSnakeCaseKeys() throws {
        // The on-the-wire format is shared with the proxy (which returns
        // snake_case via tool_use). Lock the rendered JSON so a stray
        // CodingKey change can't silently break Firestore docs that were
        // written by an older client.
        let json = try JSONEncoder().encode(makeReview())
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])

        XCTAssertNotNil(dict["summary"])
        XCTAssertNotNil(dict["key_moments"], "should use snake_case key_moments, not keyMoments")
        XCTAssertNil(dict["keyMoments"],     "Swift property name must not leak through")
        XCTAssertNotNil(dict["tip"])

        let moments = try XCTUnwrap(dict["key_moments"] as? [[String: Any]])
        let first = try XCTUnwrap(moments.first)
        XCTAssertEqual(first["kind"] as? String, "good_question",
                       "Moment.Kind rawValue must use snake_case for wire compatibility")
    }

    func testDecodesAllMomentKinds() throws {
        let json = """
        {
          "summary": "s",
          "key_moments": [
            {"turn": 1, "kind": "good_question",   "comment": "c"},
            {"turn": 2, "kind": "wrong_direction", "comment": "c"},
            {"turn": 3, "kind": "breakthrough",    "comment": "c"},
            {"turn": 4, "kind": "got_stuck",       "comment": "c"}
          ],
          "tip": "t"
        }
        """.data(using: .utf8)!

        let review = try JSONDecoder().decode(GameReview.self, from: json)
        let kinds = review.keyMoments.map { $0.kind }
        XCTAssertEqual(kinds, [.goodQuestion, .wrongDirection, .breakthrough, .gotStuck])
    }

    // MARK: - CoreData backfill on dedup

    func testSaveRecordWithReviewPersistsBlob() {
        let record = makeRecord(aiReview: makeReview())
        store.saveRecord(record)

        let roundTripped = store.review(for: record.id)
        XCTAssertEqual(roundTripped, makeReview(),
                       "review should survive a saveRecord -> review(for:) round trip")
    }

    func testRecordWithoutReviewReadsBackAsNil() {
        let record = makeRecord(aiReview: nil)
        store.saveRecord(record)
        XCTAssertNil(store.review(for: record.id),
                     "saving a record with no review must not synthesize one")
    }

    func testUpdateAIReviewAttachesToExistingRecord() {
        let record = makeRecord(aiReview: nil)
        store.saveRecord(record)

        let review = makeReview()
        store.updateAIReview(recordID: record.id, review: review)

        XCTAssertEqual(store.review(for: record.id), review,
                       "updateAIReview should land on the row whose id matches recordID")
    }

    func testSaveRecordBackfillsAIReviewOnDedupHit() {
        // Simulates the cross-device sync case: row already exists locally
        // (created at game time, no review), then we pull a remote copy that
        // now has aiReview attached. saveRecord should backfill, not skip.
        let id = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.saveRecord(makeRecord(id: id, startedAt: startedAt, aiReview: nil))
        XCTAssertNil(store.review(for: id))

        // Same (puzzleID, startedAt) but now carrying a review.
        let incoming = makeRecord(id: id, startedAt: startedAt, aiReview: makeReview())
        store.saveRecord(incoming)

        XCTAssertEqual(store.review(for: id), makeReview(),
                       "saveRecord's dedup path must backfill aiReview when local is missing it")
    }

    func testUpdateAIReviewIsNoOpForUnknownRecordID() {
        // Defensive: if the caller passes a stale recordID (e.g. record was
        // deleted by hand), updateAIReview shouldn't crash or create a row.
        let unknown = UUID()
        store.updateAIReview(recordID: unknown, review: makeReview())
        XCTAssertNil(store.review(for: unknown))
    }

    func testRecordIDPersistedVerbatim() {
        // Regression guard for the saveRecord-uses-UUID() bug fixed in the
        // post-game-review commit. record.id MUST be persisted as-is so the
        // caller can later attach a review by that same id.
        let id = UUID()
        store.saveRecord(makeRecord(id: id, aiReview: nil))

        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.predicate = NSPredicate(format: "puzzleID == %@", makePuzzleID() as CVarArg)
        let row = try? PersistenceController.test.ctx.fetch(req).first
        XCTAssertEqual(row?.value(forKey: "id") as? UUID, id,
                       "local id column must equal record.id, not a freshly-minted UUID")
    }

    // MARK: - Fixtures

    private static let stablePuzzleID = UUID()
    private func makePuzzleID() -> UUID { Self.stablePuzzleID }

    private func makeRecord(id: UUID = UUID(),
                            startedAt: Date = Date(timeIntervalSince1970: 2_000_000),
                            aiReview: GameReview?) -> GameRecord {
        GameRecord(
            id: id,
            puzzleID: makePuzzleID(),
            puzzleTitle: "测试题",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            isWon: true,
            questionCount: 5,
            messages: [],
            aiReview: aiReview
        )
    }

    private func makeReview() -> GameReview {
        GameReview(
            summary: "你用 5 轮解出了真相。",
            keyMoments: [
                .init(turn: 1, kind: .goodQuestion,   comment: "切入角度对"),
                .init(turn: 3, kind: .breakthrough,   comment: "想到墙的隔音问题是关键"),
            ],
            tip: "下次先看物理约束"
        )
    }

    private func clearRecords() {
        let ctx = PersistenceController.test.ctx
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        ((try? ctx.fetch(req)) ?? []).forEach { ctx.delete($0) }
        PersistenceController.test.save()
    }
}
