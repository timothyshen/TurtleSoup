import SwiftUI

struct SidebarView: View {

    @Binding var selectedPuzzle: Puzzle?
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var sidebarTab: SidebarTab
    @Binding var editingPuzzle: Puzzle?
    @Binding var selectedHistoryRecord: GameRecord?
    @Bindable var store: PuzzleStore
    @Bindable var recordStore: GameRecordStore
    var publicStore: PublicPuzzleStore
    var onNew: () -> Void
    @Environment(AuthService.self) private var authService
    @State private var searchText = ""
    @State private var difficultyFilter: Puzzle.Difficulty? = nil
    // iOS-only: ⌘, doesn't exist on iPhone, so settings must be a sheet.
    // On macOS this stays false — SettingsLink opens the Settings scene.
    @State private var showSettingsSheet = false

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
            // iOS: render the app title inline at the top of the sidebar.
            // We hide the system nav bar entirely below (.toolbar hidden)
            // because NavigationSplitView in compact mode ignores our
            // navigationBarTitleDisplayMode override and renders the title
            // in giant Large Title mode regardless, eating ~140pt.
            //
            // We use the SF Symbol "tortoise.fill" rather than the 🐢 emoji
            // here because the iOS Simulator ships with an incomplete
            // Apple Color Emoji font and renders 🐢 (U+1F422) as a .notdef
            // box. SF Symbols are bundled in the system and always
            // resolve. On real iPhone hardware the emoji works fine, but
            // the symbol is also stylistically tighter at title sizes.
            #if os(iOS)
            HStack(spacing: 6) {
                Image(systemName: "tortoise.fill")
                    .foregroundStyle(.green)
                Text("海龟汤")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
            #endif

            // Tab 切换 — 5 个 tab 用 segmented picker 在 240pt sidebar 里
            // 每段只剩 ~40pt，文字被挤扁。改成自建 icon + 文字 stack 的 button
            // 行，每个 tab 等宽、上下两层（icon 一层、文字一层），即使 5 个也
            // 不挤；macOS 14+ / iOS 17+ 通用，无需 #if。
            tabBar
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 6)

            if sidebarTab == .library {
                // 搜索框 — 自建而非 .searchable(placement:.sidebar)。后者在我们
                // 这个自定义 VStack 头部里光标和 placeholder 会差几个像素，看着
                // 别扭。TextField + 放大镜图标手动拼，对齐就在自己手里。
                searchField
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                // 过滤栏
                filterBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                Divider()

                // 题目列表
                List(filtered, selection: $selectedPuzzle) { puzzle in
                    PuzzleRow(puzzle: puzzle)
                        .tag(puzzle)
                }
                // .sidebar style on iPhone wraps rows in chunky inset
                // groups and adds noticeable padding around the list,
                // leaving a slab of empty space below short lists. .plain
                // packs rows edge-to-edge with the surrounding chrome.
                // macOS keeps .sidebar — that's where the style was
                // designed to live.
                #if os(macOS)
                .listStyle(.sidebar)
                #else
                .listStyle(.plain)
                #endif
                // Auto-collapse on select was removed: it conflicted with
                // macOS's native NavigationSplitView sidebar toggle. The
                // user clicking the top-left chevron to re-show the sidebar
                // would race against the binding we'd written to .detailOnly,
                // freezing the transition animation. Macs have screen space —
                // leave both columns up by default; user can manually
                // collapse via ⌘0 or the toolbar toggle.
            } else if sidebarTab == .create {
                MyPuzzlesSidebarView(editingPuzzle: $editingPuzzle, store: store, onNew: onNew)
            } else if sidebarTab == .history {
                HistorySidebarList(
                    recordStore: recordStore,
                    selectedRecord: $selectedHistoryRecord
                )
            } else if sidebarTab == .square {
                PublicSquareView(
                    publicStore: publicStore,
                    selectedPuzzle: $selectedPuzzle,
                    columnVisibility: $columnVisibility
                )
            } else {
                // .room — multiplayer entry
                RoomSidebarView()
            }

            Divider()

            // API Key 状态
            apiKeyFooter
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .navigationTitle("🐢 海龟汤")
        #if os(macOS)
        .frame(minWidth: 240)
        #else
        // iOS: completely hide the system nav bar on this root. We render
        // our own inline title at the top of the VStack above (see the
        // HStack with "🐢 海龟汤"). Without this, NavigationSplitView in
        // compact mode shows a Large Title bar despite our display-mode
        // override.
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #if os(iOS)
        .sheet(isPresented: $showSettingsSheet) {
            NavigationStack {
                SettingsView(authService: authService)
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showSettingsSheet = false }
                        }
                    }
            }
        }
        #endif
    }

    // MARK: - Tab bar

    /// All 5 sidebar tabs in a single typed list — keeps the bar's
    /// rendering trivial and means adding a 6th tab is a 1-line change.
    private static let tabs: [(SidebarTab, String, String)] = [
        (.library, "题库", "books.vertical"),
        (.create,  "出题", "square.and.pencil"),
        (.square,  "广场", "globe.asia.australia"),
        (.history, "历史", "clock.arrow.circlepath"),
        (.room,    "联机", "person.3"),
    ]

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Self.tabs, id: \.0) { (tab, label, icon) in
                Button {
                    sidebarTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .medium))
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        // Selection chip — subtle accent tint behind active
                        // tab, no border so neighboring tabs don't fight
                        // for visual weight.
                        sidebarTab == tab
                            ? Color.accentColor.opacity(0.18)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .foregroundStyle(sidebarTab == tab ? Color.accentColor : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索谜题", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
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

    /// Account status indicator. Replaces the old "API Key 已配置 / 未配置"
    /// footer — that distinction no longer exists since the proxy is
    /// hardcoded. Now the only thing the user can do wrong is forget to
    /// log in.
    private var apiKeyFooter: some View {
        HStack(spacing: 6) {
            Circle()
                .frame(width: 7, height: 7)
                .foregroundStyle(authService.isSignedIn ? .green : .red)
            Text(authService.isSignedIn ? "已登录 \(authService.displayName)" : "未登录")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            // Always offer a settings entry. Pre-P-something it only
            // appeared when signed-out (label "登录"), which meant a
            // logged-in user had no in-app way to sign out other than
            // ⌘,. Now: signed-out shows "登录" (sends to settings);
            // signed-in shows a gear icon (also sends to settings,
            // where the "退出登录" button lives).
            #if os(macOS)
            // SettingsLink: macOS 14+ official way to open the Settings
            // scene from arbitrary UI. Avoids the deprecated NSApp
            // sendAction(showSettingsWindow:) nag.
            SettingsLink {
                if authService.isSignedIn {
                    Image(systemName: "gearshape")
                        .font(.caption)
                } else {
                    Text("登录").font(.caption)
                }
            }
            .buttonStyle(.link)
            #else
            // iOS: no Settings scene — pop a sheet instead.
            Button {
                showSettingsSheet = true
            } label: {
                if authService.isSignedIn {
                    Image(systemName: "gearshape")
                        .font(.caption)
                } else {
                    Text("登录").font(.caption)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            #endif
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
                #if os(macOS)
                .listStyle(.sidebar)
                #else
                .listStyle(.plain)
                #endif
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
