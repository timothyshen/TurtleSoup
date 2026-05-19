import SwiftUI

enum SidebarTab { case library, create, square }

struct RootView: View {

    @AppStorage("claude_api_key") private var apiKey = ""
    @AppStorage("proxy_endpoint") private var proxyEndpoint = ""
    @Environment(AuthService.self) private var authService
    @State private var selectedPuzzle: Puzzle? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarTab: SidebarTab = .library
    @State private var editingPuzzle: Puzzle? = nil
    @State private var newPuzzleToken: UUID = UUID()
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
                store: store,
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
                        transport: makeTransport(),
                        recordStore: recordStore,
                        reviewConfig: makeReviewConfig()
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
            }
        }
        .task(id: authService.user?.uid) {
            // Runs on first appear AND every time uid changes (login/logout).
            let uid = authService.user?.uid
            recordStore.currentUID = uid
            store.currentUID = uid
            if let uid {
                await recordStore.syncFromFirestore(uid: uid)
                await store.syncFromFirestore(uid: uid)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
    }

    /// Build a Claude transport based on current settings:
    /// - If `proxy_endpoint` is set, route through the haiguitang Vercel proxy
    ///   and authenticate with a fresh Firebase ID Token.
    /// - Otherwise, fall back to direct Anthropic calls with the local API key.
    private func makeTransport() -> ClaudeService.Transport {
        if !proxyEndpoint.isEmpty, let url = URL(string: proxyEndpoint) {
            // Capture authService weakly via reference; closure hops to MainActor
            // on `await` since getIDToken is @MainActor-isolated.
            return .proxy(baseURL: url) { [authService] in
                try await authService.getIDToken()
            }
        } else {
            return .direct(apiKey: apiKey)
        }
    }

    /// Build a generator config from the same proxy settings. Returns nil if
    /// no proxy is configured — AI puzzle generation requires the proxy
    /// (we don't want to expose tool_use orchestration via direct key paths).
    private func makeGeneratorConfig() -> PuzzleGenerationService.Config? {
        guard !proxyEndpoint.isEmpty, let url = URL(string: proxyEndpoint) else {
            return nil
        }
        return PuzzleGenerationService.Config(baseURL: url) { [authService] in
            try await authService.getIDToken()
        }
    }

    /// Same gating as makeGeneratorConfig — review generation also lives on
    /// the proxy. Returns nil if proxy isn't configured, which hides the
    /// "生成 AI 复盘" button entirely rather than showing a non-functional one.
    private func makeReviewConfig() -> ReviewService.Config? {
        guard !proxyEndpoint.isEmpty, let url = URL(string: proxyEndpoint) else {
            return nil
        }
        return ReviewService.Config(baseURL: url) { [authService] in
            try await authService.getIDToken()
        }
    }
}
