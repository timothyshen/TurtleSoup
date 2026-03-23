import SwiftUI

enum SidebarTab { case library, create }

struct RootView: View {

    @AppStorage("claude_api_key") private var apiKey = ""
    @State private var selectedPuzzle: Puzzle? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarTab: SidebarTab = .library
    @State private var editingPuzzle: Puzzle? = nil
    @State private var newPuzzleToken: UUID = UUID()
    @State private var store = PuzzleStore()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selectedPuzzle: $selectedPuzzle,
                columnVisibility: $columnVisibility,
                sidebarTab: $sidebarTab,
                editingPuzzle: $editingPuzzle,
                store: store,
                onNew: {
                    editingPuzzle = nil
                    newPuzzleToken = UUID()
                }
            )
        } detail: {
            if sidebarTab == .library {
                if let puzzle = selectedPuzzle {
                    GameView(puzzle: puzzle, apiKey: apiKey)
                        .id(puzzle.id)   // 切题时强制重建 ViewModel
                } else {
                    EmptyDetailView()
                }
            } else {
                PuzzleEditorView(editingPuzzle: $editingPuzzle, store: store)
                    .id(editingPuzzle?.id.uuidString ?? newPuzzleToken.uuidString)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
    }
}
