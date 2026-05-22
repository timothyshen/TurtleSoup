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
                    isPublicPuzzle: sidebarTab == .square
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
    /// Custom layout that bypasses iOS 26's TabView. The system TabView
    /// in iOS 26 wraps tab content in a rounded "card" with a floating
    /// Liquid Glass tab bar — that leaves ~25% of black background above
    /// the content. UITabBar.appearance() doesn't override the new
    /// presentation, and there's no public knob to opt out. So we just
    /// hand-roll it: VStack { currentTabContent; bottomTabBar } with full
    /// control over edges, insets, and shape.
    @ViewBuilder
    private var iOSLayout: some View {
        VStack(spacing: 0) {
            currentTabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            customTabBar
        }
        // Explicit color background — `.background(.bar)` or any material
        // gets the iOS 26 Liquid Glass treatment (rounded capsule, glassy
        // blur). Color(.systemBackground) stays flat and edge-to-edge.
        .background(Color(.systemBackground))
        // Fill the screen edge-to-edge. Without this the WindowGroup may
        // inset our content for "tab carousel" presentation on iOS 26.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.keyboard)
    }

    @ViewBuilder
    private var currentTabContent: some View {
        switch sidebarTab {
        case .library:
            LibraryTab(
                store: store,
                recordStore: recordStore,
                authService: authService,
                publicStore: publicStore,
                makeClaudeConfig: makeClaudeConfig,
                makeReviewConfig: makeReviewConfig,
                makeGeneratorConfig: makeGeneratorConfig
            )
        case .create:
            CreateTab(
                store: store,
                authService: authService,
                publicStore: publicStore,
                makeGeneratorConfig: makeGeneratorConfig
            )
        case .square:
            SquareTab(
                publicStore: publicStore,
                recordStore: recordStore,
                makeClaudeConfig: makeClaudeConfig,
                makeReviewConfig: makeReviewConfig
            )
        case .history:
            HistoryTab(
                recordStore: recordStore,
                store: store,
                makeReviewConfig: makeReviewConfig
            )
        case .room:
            RoomTab(
                publicStore: publicStore,
                puzzleStore: store
            )
        }
    }

    private var customTabBar: some View {
        HStack(spacing: 0) {
            tabButton(.library, label: "题库",  icon: "books.vertical.fill")
            tabButton(.create,  label: "出题",  icon: "square.and.pencil")
            tabButton(.square,  label: "广场",  icon: "globe")
            tabButton(.history, label: "历史",  icon: "clock.arrow.circlepath")
            tabButton(.room,    label: "联机",  icon: "person.3.fill")
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        // Solid color — avoid `.background(.bar)` because iOS 26 renders
        // material backgrounds as floating Liquid Glass capsules.
        .background(Color(.secondarySystemBackground))
    }

    private func tabButton(_ tab: SidebarTab, label: String, icon: String) -> some View {
        Button {
            sidebarTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(label)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(sidebarTab == tab ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
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
