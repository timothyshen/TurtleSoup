import SwiftUI

struct SidebarView: View {

    @Binding var selectedPuzzle: Puzzle?
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var sidebarTab: SidebarTab
    @Binding var editingPuzzle: Puzzle?
    @Bindable var store: PuzzleStore
    var onNew: () -> Void
    @AppStorage("claude_api_key") private var apiKey = ""
    @State private var searchText = ""
    @State private var difficultyFilter: Puzzle.Difficulty? = nil

    private var puzzles: [Puzzle] { Puzzle.builtIn + store.puzzles }

    private var filtered: [Puzzle] {
        puzzles.filter { p in
            let matchSearch = searchText.isEmpty ||
                p.title.localizedCaseInsensitiveContains(searchText) ||
                p.scenario.localizedCaseInsensitiveContains(searchText)
            let matchDiff = difficultyFilter == nil || p.difficulty == difficultyFilter
            return matchSearch && matchDiff
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab 切换
            Picker("", selection: $sidebarTab) {
                Text("题库").tag(SidebarTab.library)
                Text("出题").tag(SidebarTab.create)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if sidebarTab == .library {
                // 过滤栏
                filterBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.bar)

                Divider()

                // 题目列表
                List(filtered, selection: $selectedPuzzle) { puzzle in
                    PuzzleRow(puzzle: puzzle)
                        .tag(puzzle)
                }
                .listStyle(.sidebar)
                .searchable(text: $searchText, placement: .sidebar, prompt: "搜索谜题")
                .onChange(of: selectedPuzzle) {
                    if selectedPuzzle != nil {
                        withAnimation {
                            columnVisibility = .detailOnly  // ← 选题后收起
                        }
                    }
                }
            } else {
                MyPuzzlesSidebarView(editingPuzzle: $editingPuzzle, store: store, onNew: onNew)
            }

            Divider()

            // API Key 状态
            apiKeyFooter
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .navigationTitle("🐢 海龟汤")
        .frame(minWidth: 240)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(label: "全部", isOn: difficultyFilter == nil) {
                    difficultyFilter = nil
                }
                ForEach(Puzzle.Difficulty.allCases, id: \.self) { diff in
                    FilterChip(label: diff.rawValue, isOn: difficultyFilter == diff) {
                        difficultyFilter = (difficultyFilter == diff) ? nil : diff
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var apiKeyFooter: some View {
        HStack(spacing: 6) {
            Circle()
                .frame(width: 7, height: 7)
                .foregroundStyle(apiKey.isEmpty ? .red : .green)
            Text(apiKey.isEmpty ? "未配置 API Key" : "API Key 已配置")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if apiKey.isEmpty {
                Button("前往设置") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
    }
}

// MARK: - My Puzzles Sidebar

struct MyPuzzlesSidebarView: View {

    @Binding var editingPuzzle: Puzzle?
    @Bindable var store: PuzzleStore
    var onNew: () -> Void

    var body: some View {
        Group {
            if store.puzzles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "pencil.and.list.clipboard")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    Text("还没有自制题目\n点击「新建」开始创作")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.puzzles, selection: $editingPuzzle) { puzzle in
                    PuzzleRow(puzzle: puzzle)
                        .tag(puzzle)
                }
                .listStyle(.sidebar)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    onNew()
                } label: {
                    Label("新建", systemImage: "plus")
                }
            }
        }
    }
}

// MARK: - Filter chip

struct FilterChip: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isOn ? Color.accentColor.opacity(0.15) : Color.clear)
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .overlay(
                    Capsule().stroke(
                        isOn ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.25),
                        lineWidth: 0.5
                    )
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Puzzle row

struct PuzzleRow: View {
    let puzzle: Puzzle

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(puzzle.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                DifficultyBadge(difficulty: puzzle.difficulty)
            }
            Text(puzzle.scenario)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .lineSpacing(2)
            Text("by \(puzzle.author)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Difficulty badge

struct DifficultyBadge: View {
    let difficulty: Puzzle.Difficulty

    var body: some View {
        Text(difficulty.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch difficulty {
        case .easy:   return .teal
        case .medium: return .orange
        case .hard:   return .red
        }
    }
}

// MARK: - Empty detail

struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("选择一道谜题开始游戏")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("或在左侧搜索感兴趣的题目")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
