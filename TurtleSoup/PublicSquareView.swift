import SwiftUI

struct PublicSquareView: View {

    var publicStore: PublicPuzzleStore
    @Binding var selectedPuzzle: Puzzle?
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        Group {
            if publicStore.isLoading {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if publicStore.puzzles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    Text("广场暂无题目")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("在「出题」Tab 完成题目后可发布到广场")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(publicStore.puzzles, selection: $selectedPuzzle) { puzzle in
                    PuzzleRow(puzzle: puzzle)
                        .tag(puzzle)
                }
                .listStyle(.sidebar)
                .onChange(of: selectedPuzzle) {
                    if selectedPuzzle != nil {
                        withAnimation { columnVisibility = .detailOnly }
                    }
                }
            }
        }
        .task { await publicStore.fetchIfNeeded() }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await publicStore.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(publicStore.isLoading)
            }
        }
    }
}
