import SwiftUI

enum SidebarTab: Hashable { case library, create, square, history, room }

struct RootView: View {

    @Environment(AuthService.self) private var authService
    @State private var selectedPuzzle: Puzzle? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarTab: SidebarTab = .library
    @State private var editingPuzzle: Puzzle? = nil
    @State private var newPuzzleToken: UUID = UUID()
    @State private var selectedHistoryRecord: GameRecord? = nil
    @State private var store = PuzzleStore()
    @State private var recordStore = GameRecordStore()
    @State private var publicStore = PublicPuzzleStore()

    var body: some View {
        Group {
            #if os(macOS)
            macOSLayout
            #else
            iOSLayout
            #endif
        }
        .task(id: authService.uid) {
            // Runs on first appear AND every time uid changes (login/logout).
            let uid = authService.uid
            recordStore.currentUID = uid
            store.currentUID = uid
            if let uid {
                await recordStore.syncFromFirestore(uid: uid)
                await store.syncFromFirestore(uid: uid)
            }
        }
    }

    // MARK: - macOS layout (NavigationSplitView)

    #if os(macOS)
    @ViewBuilder
    private var macOSLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selectedPuzzle: $selectedPuzzle,
                columnVisibility: $columnVisibility,
                sidebarTab: $sidebarTab,
                editingPuzzle: $editingPuzzle,
                selectedHistoryRecord: $selectedHistoryRecord,
                store: store,
                recordStore: recordStore,
                publicStore: publicStore,
                onNew: {
                    editingPuzzle = nil
                    newPuzzleToken = UUID()
                }
            )
        } detail: {
            macOSDetail
        }
        .navigationSplitViewStyle(.balanced)
        // Min width must accommodate: sidebar (~220) + GameView's chatPane
        // minWidth (460) + infoPane fixed width (260) = 940. Add 60px buffer
        // for column dividers, toolbar margins. Under-sized window caused
        // sidebar-toggle animations to freeze mid-flight — SwiftUI thrashes
        // on layout passes trying to fit content that doesn't fit.
        .frame(minWidth: 1000, minHeight: 600)
    }

    @ViewBuilder
    private var macOSDetail: some View {
        switch sidebarTab {
        case .library, .square:
            if let puzzle = selectedPuzzle {
                GameView(
                    puzzle: puzzle,
                    claudeConfig: makeClaudeConfig(),
                    recordStore: recordStore,
                    reviewConfig: makeReviewConfig(),
                    isPublicPuzzle: sidebarTab == .square,
                    onPlayNext: { advanceToNextPuzzle(after: puzzle) }
                )
                .id(puzzle.id)
            } else {
                EmptyDetailView()
            }
        case .create:
            PuzzleEditorView(
                editingPuzzle: $editingPuzzle,
                store: store,
                authService: authService,
                publicStore: publicStore,
                generatorConfig: makeGeneratorConfig()
            )
            .id(editingPuzzle?.id.uuidString ?? newPuzzleToken.uuidString)
        case .history:
            if let record = selectedHistoryRecord {
                HistoryDetailView(
                    record: record,
                    reviewConfig: makeReviewConfig(),
                    recordStore: recordStore,
                    puzzleStore: store
                )
                .id(record.id)
            } else {
                HistoryOverviewView(recordStore: recordStore)
            }
        case .room:
            MultiplayerDetailView(
                publicStore: publicStore,
                puzzleStore: store
            )
        }
    }

    /// 下一题 (macOS): random unplayed puzzle from the active tab's pool,
    /// falling back to any other one. Swapping selectedPuzzle rebuilds
    /// GameView via .id(puzzle.id).
    private func advanceToNextPuzzle(after current: Puzzle) {
        let pool: [Puzzle] = sidebarTab == .square
            ? publicStore.puzzles
            : Puzzle.builtIn + store.puzzles
        let others = pool.filter { $0.id != current.id }
        guard !others.isEmpty else { return }
        let unplayed = others.filter { recordStore.playCount(for: $0.id) == 0 }
        selectedPuzzle = (unplayed.randomElement() ?? others.randomElement())
    }
    #endif

    // MARK: - iOS layout (TabView)
    //
    // iPhone goes through TabView rather than NavigationSplitView because
    // NavigationSplitView's compact-mode sidebar (a) renders a huge Large
    // Title nav bar that's impossible to suppress with the public API
    // (.toolbar(.hidden, for: .navigationBar) is ignored on the sidebar
    // column), and (b) the system .listStyle(.sidebar) treatment wastes
    // ~30% of the viewport on chrome.
    //
    // TabView is also the iPhone-native pattern for top-level navigation
    // between sections. Each tab gets its own NavigationStack so push
    // navigation to the detail (game / editor / history detail) stays
    // local to that tab — switching tabs doesn't reset the others.

    #if !os(macOS)
    /// iOS uses the system TabView. With UILaunchScreen_Generation set in
    /// the Info.plist (see project.pbxproj), iOS runs us as a modern
    /// fullscreen app and TabView renders with the iOS 26 Liquid Glass
    /// floating capsule at the bottom — which is what we want.
    ///
    /// Earlier we tried a hand-rolled tab bar to dodge what looked like
    /// "Liquid Glass eating content space", but that was actually the
    /// legacy-scaling letterbox (the launch screen key was missing).
    /// Fixing the launch screen made the Liquid Glass tab bar correct.
    @ViewBuilder
    private var iOSLayout: some View {
        TabView(selection: $sidebarTab) {
            LibraryTab(
                store: store,
                recordStore: recordStore,
                authService: authService,
                publicStore: publicStore,
                makeClaudeConfig: makeClaudeConfig,
                makeReviewConfig: makeReviewConfig,
                makeGeneratorConfig: makeGeneratorConfig
            )
            .tabItem { Label("题库", systemImage: "books.vertical.fill") }
            .tag(SidebarTab.library)

            CreateTab(
                store: store,
                authService: authService,
                publicStore: publicStore,
                makeGeneratorConfig: makeGeneratorConfig
            )
            .tabItem { Label("出题", systemImage: "square.and.pencil") }
            .tag(SidebarTab.create)

            SquareTab(
                publicStore: publicStore,
                recordStore: recordStore,
                makeClaudeConfig: makeClaudeConfig,
                makeReviewConfig: makeReviewConfig
            )
            .tabItem { Label("广场", systemImage: "globe") }
            .tag(SidebarTab.square)

            HistoryTab(
                recordStore: recordStore,
                store: store,
                makeReviewConfig: makeReviewConfig
            )
            .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
            .tag(SidebarTab.history)

            RoomTab(
                publicStore: publicStore,
                puzzleStore: store
            )
            .tabItem { Label("联机", systemImage: "person.3.fill") }
            .tag(SidebarTab.room)
        }
    }
    #endif

    // MARK: - Config builders
    //
    // All three services share the same baseURL (hardcoded in AppConfig)
    // + the same ID token provider, so the three helpers are nearly
    // identical — just different struct types.

    private func makeClaudeConfig() -> ClaudeService.Config {
        ClaudeService.Config(baseURL: AppConfig.proxyBaseURL) { [authService] in
            try await authService.getIDToken()
        }
    }

    private func makeGeneratorConfig() -> PuzzleGenerationService.Config {
        PuzzleGenerationService.Config(baseURL: AppConfig.proxyBaseURL) { [authService] in
            try await authService.getIDToken()
        }
    }

    private func makeReviewConfig() -> ReviewService.Config {
        ReviewService.Config(baseURL: AppConfig.proxyBaseURL) { [authService] in
            try await authService.getIDToken()
        }
    }
}
