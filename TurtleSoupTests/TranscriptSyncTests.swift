import XCTest
import CoreData
@testable import TurtleSoup

/// Covers the transcript-blob path added by N2:
/// - Message round-trips through JSON (Codable conformance)
/// - GameRecordStore.messages(for:) reads CoreData rows back as [Message]
/// - saveRecord's dedup hit backfills GameMessageEntity rows from incoming
///   record.messages when local has none (cross-device sync scenario)
/// - Realistic 50-turn transcript fits well under Firestore's 1MB doc cap
@MainActor
final class TranscriptSyncTests: XCTestCase {

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

    func testMessageRoundTripsThroughJSON() throws {
        let original = Message(
            id: UUID(),
            role: .assistant,
            text: "对了",
            verdict: .yes,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testArrayOfMessagesRoundTrips() throws {
        let messages = sampleTranscript(turns: 5)
        let data = try JSONEncoder().encode(messages)
        let decoded = try JSONDecoder().decode([Message].self, from: data)
        XCTAssertEqual(decoded, messages)
    }

    // MARK: - Local read

    func testMessagesForReturnsChronologicalOrder() {
        let record = makeRecord(messages: sampleTranscript(turns: 4))
        store.saveRecord(record)

        let read = store.messages(for: record.id)
        XCTAssertEqual(read.count, 4)
        // Timestamps in sampleTranscript are strictly monotonic; verify sort.
        for i in 1..<read.count {
            XCTAssertLessThan(read[i - 1].timestamp, read[i].timestamp)
        }
        XCTAssertEqual(read.map(\.text), record.messages.map(\.text))
    }

    func testMessagesForReturnsEmptyForUnknownRecord() {
        XCTAssertEqual(store.messages(for: UUID()), [])
    }

    func testMessagesForReturnsEmptyWhenRecordHasNoMessages() {
        let record = makeRecord(messages: [])
        store.saveRecord(record)
        XCTAssertEqual(store.messages(for: record.id), [])
    }

    // MARK: - Cross-device dedup backfill

    func testDedupHitBackfillsMessagesWhenLocalIsEmpty() {
        // Simulates: device B previously synced this record's metadata only
        // (pre-N2, no messagesJSON in Firestore). Now device A's record
        // arrives via syncFromFirestore carrying messages. Dedup matches by
        // (puzzleID, startedAt), but local row has no messages — backfill.
        let id = UUID()
        let started = Date(timeIntervalSince1970: 1_700_000_000)

        // Stage 1: empty local record.
        store.saveRecord(makeRecord(id: id, startedAt: started, messages: []))
        XCTAssertEqual(store.messages(for: id), [])

        // Stage 2: incoming carries a full transcript.
        let incoming = makeRecord(id: id, startedAt: started, messages: sampleTranscript(turns: 3))
        store.saveRecord(incoming)

        XCTAssertEqual(store.messages(for: id).count, 3,
                       "dedup path must backfill messages when local has none")
    }

    func testDedupHitDoesNotDuplicateExistingMessages() {
        // If local already has messages, dedup should not re-insert them
        // (would double the transcript).
        let id = UUID()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let transcript = sampleTranscript(turns: 3)

        store.saveRecord(makeRecord(id: id, startedAt: started, messages: transcript))
        XCTAssertEqual(store.messages(for: id).count, 3)

        // Same incoming again (e.g. another sync).
        store.saveRecord(makeRecord(id: id, startedAt: started, messages: transcript))
        XCTAssertEqual(store.messages(for: id).count, 3,
                       "dedup must not duplicate messages on re-sync")
    }

    // MARK: - Size sanity check

    func testFiftyTurnTranscriptFitsWellUnderFirestoreDocLimit() throws {
        // Firestore caps a document at 1,048,576 bytes. We claim a 50-turn
        // game is ≈ 5KB — verify the claim so we don't get a runtime surprise
        // when someone plays an extra-chatty game. Headroom check, not a
        // strict size assertion.
        let transcript = sampleTranscript(turns: 50)
        let data = try JSONEncoder().encode(transcript)
        XCTAssertLessThan(data.count, 50_000,
                          "50-turn transcript should be under 50KB; got \(data.count) bytes")
    }

    // MARK: - Fixtures

    private func makeRecord(id: UUID = UUID(),
                            startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
                            messages: [Message]) -> GameRecord {
        GameRecord(
            id: id,
            puzzleID: UUID(),
            puzzleTitle: "测试题",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            isWon: true,
            questionCount: messages.filter { $0.role == .user }.count,
            messages: messages
        )
    }

    /// Build a transcript with strictly-increasing timestamps so order
    /// assertions are meaningful.
    private func sampleTranscript(turns: Int) -> [Message] {
        var msgs: [Message] = []
        let base = Date(timeIntervalSince1970: 1_700_000_100)
        for i in 0..<turns {
            let userTS = base.addingTimeInterval(TimeInterval(i * 30))
            let asstTS = base.addingTimeInterval(TimeInterval(i * 30 + 15))
            msgs.append(Message(id: UUID(), role: .user,
                                text: "玩家提问 \(i + 1)",
                                verdict: nil, timestamp: userTS))
            msgs.append(Message(id: UUID(), role: .assistant,
                                text: "对",
                                verdict: .yes, timestamp: asstTS))
        }
        return msgs
    }

    private func clearRecords() {
        let ctx = PersistenceController.test.ctx
        for entity in ["GameRecordEntity", "GameMessageEntity"] {
            let req = NSFetchRequest<NSManagedObject>(entityName: entity)
            ((try? ctx.fetch(req)) ?? []).forEach { ctx.delete($0) }
        }
        PersistenceController.test.save()
    }
}
