import XCTest
import CoreData
@testable import TurtleSoup

// Uses MockURLProtocol from PuzzleGenerationServiceTests.swift.

@MainActor
final class GameViewModelTests: XCTestCase {

    private var session: URLSession!
    private var recordStore: GameRecordStore!
    private var firestoreMock: MockFirestoreService!

    override func setUp() {
        super.setUp()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: cfg)
        MockURLProtocol.reset()

        firestoreMock = MockFirestoreService()
        recordStore = GameRecordStore(pc: .test, firestore: firestoreMock)
        clearRecords()
    }

    override func tearDown() {
        clearRecords()
        MockURLProtocol.reset()
        session = nil
        recordStore = nil
        firestoreMock = nil
        super.tearDown()
    }

    // MARK: - Public playCount writeback

    func testWinOnPublicPuzzleIncrementsRemotePlayCount() async throws {
        let puzzleID = UUID()
        MockURLProtocol.requestHandler = { _ in
            (200, [:], anthropicSSEBody(verdict: "win", comment: "对了"))
        }
        let vm = makeVM(puzzle: makePuzzle(id: puzzleID), isPublic: true)
        vm.inputText = "他认识凶手吗？"
        vm.send()
        try await waitForLoadingToClear(vm)
        // Increment is fire-and-forget Task — give it a tick.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(firestoreMock.publicPlayCountIncrements, [puzzleID])
    }

    func testGiveUpOnPublicPuzzleIncrementsRemotePlayCount() async throws {
        let puzzleID = UUID()
        let vm = makeVM(puzzle: makePuzzle(id: puzzleID), isPublic: true)
        vm.giveUp()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(firestoreMock.publicPlayCountIncrements, [puzzleID],
                       "give-up should also count toward public playCount")
    }

    func testNonPublicPuzzleSkipsRemoteIncrement() async throws {
        let vm = makeVM(isPublic: false)
        vm.giveUp()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(firestoreMock.publicPlayCountIncrements.isEmpty,
                      "private/built-in puzzles must not touch publicPuzzles")
    }

    // MARK: - send() optimistic updates

    func testSendAppendsUserMessageAndIncrementsCountImmediately() async throws {
        MockURLProtocol.requestHandler = { _ in
            (200, [:], anthropicSSEBody(verdict: "irr", comment: ""))
        }
        let vm = makeVM()

        vm.inputText = "他活着吗？"
        vm.send()

        // These mutations happen synchronously inside send() before the Task runs.
        XCTAssertEqual(vm.questionCount, 1)
        XCTAssertEqual(vm.inputText, "")
        XCTAssertTrue(vm.messages.contains(where: { $0.role == .user && $0.text == "他活着吗？" }),
                      "user message should appear in the transcript right away")
        XCTAssertTrue(vm.isLoading)

        try await waitForLoadingToClear(vm)
        XCTAssertEqual(vm.messages.last?.role, .assistant)
    }

    func testSendIgnoredWhenInputIsBlank() {
        let vm = makeVM()
        vm.inputText = "   \n\t  "
        vm.send()
        XCTAssertEqual(vm.questionCount, 0)
        XCTAssertFalse(vm.isLoading)
    }

    func testSendIgnoredWhenAlreadyLoading() {
        let vm = makeVM()
        vm.isLoading = true
        vm.inputText = "x"
        vm.send()
        XCTAssertEqual(vm.questionCount, 0,
                       "send should be a no-op while a request is already in flight")
    }

    func testSendIgnoredAfterWin() {
        let vm = makeVM()
        vm.isGameWon = true
        vm.inputText = "x"
        vm.send()
        XCTAssertEqual(vm.questionCount, 0)
    }

    // MARK: - Verdict handling

    func testIrrelevantVerdictUsesLabelWhenCommentEmpty() async throws {
        MockURLProtocol.requestHandler = { _ in
            (200, [:], anthropicSSEBody(verdict: "irr", comment: ""))
        }
        let vm = makeVM()
        vm.inputText = "天气好吗？"
        vm.send()
        try await waitForLoadingToClear(vm)

        let assistant = try XCTUnwrap(vm.messages.last)
        XCTAssertEqual(assistant.verdict, .irr)
        XCTAssertFalse(assistant.text.isEmpty,
                       "empty comment should fall back to the verdict's Chinese label")
    }

    func testNonEmptyCommentIsUsedAsBubbleText() async throws {
        MockURLProtocol.requestHandler = { _ in
            (200, [:], anthropicSSEBody(verdict: "yes", comment: "对了"))
        }
        let vm = makeVM()
        vm.inputText = "他认识凶手吗？"
        vm.send()
        try await waitForLoadingToClear(vm)

        let assistant = try XCTUnwrap(vm.messages.last)
        XCTAssertEqual(assistant.verdict, .yes)
        XCTAssertEqual(assistant.text, "对了")
    }

    // MARK: - Win path

    func testWinFlipsStateAndPersistsRecord() async throws {
        let puzzleID = UUID()
        MockURLProtocol.requestHandler = { _ in
            (200, [:], anthropicSSEBody(verdict: "win", comment: "完全猜中"))
        }
        let vm = makeVM(puzzle: makePuzzle(id: puzzleID))
        vm.inputText = "他是为了纪念亡妻"
        vm.send()
        try await waitForLoadingToClear(vm)

        XCTAssertTrue(vm.isGameWon, "win verdict should flip isGameWon")
        XCTAssertEqual(recordStore.playCount(for: puzzleID), 1,
                       "win should persist a GameRecord")
        XCTAssertEqual(recordStore.winRate(for: puzzleID), 1.0)

        // showAnswer is flipped after a 1-second delay; give it a generous margin.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(vm.showAnswer)
    }

    // MARK: - Give-up path

    func testGiveUpPersistsAsLoss() {
        let puzzleID = UUID()
        let vm = makeVM(puzzle: makePuzzle(id: puzzleID))
        vm.giveUp()

        XCTAssertTrue(vm.isGameWon, "giveUp should lock further input via isGameWon")
        XCTAssertTrue(vm.showAnswer)
        XCTAssertEqual(recordStore.playCount(for: puzzleID), 1)
        XCTAssertEqual(recordStore.winRate(for: puzzleID), 0.0,
                       "give-up records should not count toward win rate")
    }

    func testGiveUpIsNoOpWhenAlreadyWon() {
        let puzzleID = UUID()
        let vm = makeVM(puzzle: makePuzzle(id: puzzleID))
        vm.isGameWon = true   // already won — give-up should bail
        vm.giveUp()

        XCTAssertEqual(recordStore.playCount(for: puzzleID), 0,
                       "give-up after a win must not double-persist")
    }

    // MARK: - Error path

    func testServerErrorSurfacesAndClearsLoading() async throws {
        MockURLProtocol.requestHandler = { _ in (500, [:], Data("upstream boom".utf8)) }
        let vm = makeVM()
        vm.inputText = "x"
        vm.send()
        try await waitForLoadingToClear(vm)

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.isGameWon)
        XCTAssertEqual(recordStore.playCount(for: vm.puzzle.id), 0,
                       "errors must not persist a record")
    }

    // MARK: - Helpers

    private func makeVM(puzzle: Puzzle? = nil, isPublic: Bool = false) -> GameViewModel {
        let p = puzzle ?? makePuzzle()
        let claude = ClaudeService(transport: .direct(apiKey: "test-key"), session: session)
        return GameViewModel(puzzle: p, claude: claude, recordStore: recordStore, isPublicPuzzle: isPublic)
    }

    private func makePuzzle(id: UUID = UUID()) -> Puzzle {
        Puzzle(id: id, title: "测试题", difficulty: .medium,
               scenario: "汤面", answer: "汤底关键真相",
               hint: nil, author: "测试", playCount: 0)
    }

    /// Poll briefly until the VM's send() Task drains. Hard-cap to avoid
    /// hanging the suite if a regression leaves isLoading stuck on.
    private func waitForLoadingToClear(_ vm: GameViewModel, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while vm.isLoading && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(vm.isLoading, "isLoading did not clear within \(timeout)s")
    }

    private func clearRecords() {
        let ctx = PersistenceController.test.ctx
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        ((try? ctx.fetch(req)) ?? []).forEach { ctx.delete($0) }
        PersistenceController.test.save()
    }
}
