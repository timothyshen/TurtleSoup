import SwiftUI

enum SidebarTab { case library, create, square }

struct RootView: View {

    @AppStorage("claude_api_key") private var apiKey = ""
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
                    GameView(puzzle: puzzle, apiKey: apiKey, recordStore: recordStore)
                        .id(puzzle.id)
                } else {
                    EmptyDetailView()
                }
            case .create:
                PuzzleEditorView(
                    editingPuzzle: $editingPuzzle,
                    store: store,
                    authService: authService,
                    publicStore: publicStore
                )
                .id(editingPuzzle?.id.uuidString ?? newPuzzleToken.uuidString)
            }
        }
        .onChange(of: authService.user?.uid) { _, uid in
            recordStore.currentUID = uid
            store.currentUID = uid
            if let uid {
                Task { await recordStore.syncFromFirestore(uid: uid) }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
    }
}
