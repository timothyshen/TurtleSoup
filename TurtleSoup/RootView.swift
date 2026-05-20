import SwiftUI

enum SidebarTab { case library, create, square, history }

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
                    HistoryDetailView(record: record).id(record.id)
                } else {
                    HistoryOverviewView(recordStore: recordStore)
                }
            }
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
        .navigationSplitViewStyle(.balanced)
        // Min width must accommodate: sidebar (~220) + GameView's chatPane
        // minWidth (460) + infoPane fixed width (260) = 940. Add 60px buffer
        // for column dividers, toolbar margins. Under-sized window caused
        // sidebar-toggle animations to freeze mid-flight — SwiftUI thrashes
        // on layout passes trying to fit content that doesn't fit.
        .frame(minWidth: 1000, minHeight: 600)
    }

    /// Build a Claude proxy config. All three services share the same
    /// baseURL (hardcoded in AppConfig) + the same ID token provider, so
    /// the three helpers are nearly identical — just different struct types.
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
