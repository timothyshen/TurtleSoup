#if !os(macOS)
import SwiftUI

// MARK: - iOS Tab Views
//
// One self-contained view per tab in the iPhone TabView. Each owns its
// own NavigationStack so push navigation (to a GameView / editor / history
// detail) is local to the tab. The toolbar item on the leading edge
// provides access to settings (login / sign out) — without it iOS users
// have no way to reach settings.

// MARK: Tab header (shared)

/// Inline header rendered at the top of each tab's content. Replaces the
/// system nav bar (which we hide via `.toolbar(.hidden, for: .navigationBar)`
/// on each tab root) so the content can sit flush below the status bar
/// rather than burning ~44pt on a nav bar we don't need at the root level.
///
/// Pushed views (GameView, PuzzleEditorView, etc.) keep their own nav
/// bars — `.toolbar(.hidden)` is per-screen, so navigation destinations
/// downstream get the standard iOS chrome (back button included).
private struct TabHeader: View {

    let title: String
    /// Optional leading-edge action — used by 出题 tab for "+ new puzzle".
    /// nil hides the slot entirely.
    var leadingAction: (icon: String, action: () -> Void)? = nil

    @Environment(AuthService.self) private var authService
    @State private var showSettingsSheet = false

    var body: some View {
        HStack(spacing: 12) {
            if let leading = leadingAction {
                Button(action: leading.action) {
                    Image(systemName: leading.icon)
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 28, height: 28)
                }
            }
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                showSettingsSheet = true
            } label: {
                Image(systemName: authService.isSignedIn
                      ? "person.circle.fill" : "person.circle")
                    .font(.system(size: 22))
                    // Cast to Color so the ternary has a single type —
                    // .tint (TintShapeStyle) and .secondary (HierarchicalShapeStyle)
                    // are unrelated ShapeStyle subtypes that can't be merged
                    // by ternary inference.
                    .foregroundStyle(authService.isSignedIn
                                     ? Color.accentColor : Color.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
    }
}

// MARK: - 题库 Tab

struct LibraryTab: View {

    @Bindable var store: PuzzleStore
    @Bindable var recordStore: GameRecordStore
    let authService: AuthService
    var publicStore: PublicPuzzleStore
    let makeClaudeConfig: () -> ClaudeService.Config
    let makeReviewConfig: () -> ReviewService.Config
    let makeGeneratorConfig: () -> PuzzleGenerationService.Config

    @State private var searchText = ""
    @State private var difficultyFilter: Puzzle.Difficulty? = nil
    @State private var selectedPuzzle: Puzzle? = nil

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
        // TabHeader OUTSIDE NavigationStack so it sits flush below the
        // system status bar. NavigationStack reserves ~40-50pt of safe-area
        // inset for its (hidden) nav bar even when we set
        // .toolbar(.hidden, for: .navigationBar) — iOS 17 quirk. Keeping
        // the header outside means our content's top is determined by the
        // outer VStack, not by NS's chrome reservation. The push to
        // GameView still works because NS is the ancestor of the source
        // (the List with selection).
        VStack(spacing: 0) {
            TabHeader(title: "题库")
            Divider()
            NavigationStack {
                VStack(spacing: 0) {
                    inlineSearchField
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    filterChips
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    List(filtered, selection: $selectedPuzzle) { puzzle in
                        PuzzleRow(puzzle: puzzle).tag(puzzle)
                    }
                    .listStyle(.plain)
                    // Hard scroll edge mask: crisp cutoff between TabHeader/
                    // filter chips above and the scrolling list. Without it
                    // the iOS 26 default leaves a soft gradient that can
                    // look muddy when rows scroll under the fixed chrome.
                    // Bottom mask matches the Liquid Glass tab bar overlap.
                    .scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $selectedPuzzle) { puzzle in
                    GameView(
                        puzzle: puzzle,
                        claudeConfig: makeClaudeConfig(),
                        recordStore: recordStore,
                        reviewConfig: makeReviewConfig(),
                        isPublicPuzzle: false
                    )
                    .id(puzzle.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Inline search field — replaces `.searchable` since we don't have a
    /// nav bar to host it. Same shape as the macOS sidebar version.
    private var inlineSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("搜索谜题", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var filterChips: some View {
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
}

// MARK: - 出题 Tab

struct CreateTab: View {

    @Bindable var store: PuzzleStore
    let authService: AuthService
    var publicStore: PublicPuzzleStore
    let makeGeneratorConfig: () -> PuzzleGenerationService.Config

    /// nil while the list is showing; non-nil pushes the editor. A
    /// dedicated UUID token covers the "new puzzle" case (we need a fresh
    /// editor without referring to any existing puzzle).
    @State private var editingPuzzle: Puzzle? = nil
    @State private var showNewEditor = false
    @State private var newPuzzleToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: "出题", leadingAction: (
                icon: "plus",
                action: {
                    editingPuzzle = nil
                    newPuzzleToken = UUID()
                    showNewEditor = true
                }
            ))
            Divider()
            NavigationStack {
                Group {
                    if store.puzzles.isEmpty {
                        emptyState
                    } else {
                        List(store.puzzles, selection: $editingPuzzle) { puzzle in
                            PuzzleRow(puzzle: puzzle).tag(puzzle)
                        }
                        .listStyle(.plain)
                        .scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                // Two destination paths: tapping a row uses .navigationDestination(item:),
                // tapping the "+" button uses an explicit isPresented flag. They
                // share the editor view but with different .id() values so SwiftUI
                // rebuilds the form cleanly between sessions.
                .navigationDestination(item: $editingPuzzle) { puzzle in
                    PuzzleEditorView(
                        editingPuzzle: .constant(puzzle),
                        store: store,
                        authService: authService,
                        publicStore: publicStore,
                        generatorConfig: makeGeneratorConfig()
                    )
                    .id(puzzle.id.uuidString)
                }
                .navigationDestination(isPresented: $showNewEditor) {
                    PuzzleEditorView(
                        editingPuzzle: .constant(nil),
                        store: store,
                        authService: authService,
                        publicStore: publicStore,
                        generatorConfig: makeGeneratorConfig()
                    )
                    .id(newPuzzleToken.uuidString)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "pencil.and.list.clipboard")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("还没有自制题目")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("点击左上角「+」开始创作")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 广场 Tab

struct SquareTab: View {

    var publicStore: PublicPuzzleStore
    @Bindable var recordStore: GameRecordStore
    let makeClaudeConfig: () -> ClaudeService.Config
    let makeReviewConfig: () -> ReviewService.Config

    @State private var selectedPuzzle: Puzzle? = nil

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: "广场")
            Divider()
            NavigationStack {
                Group {
                    if publicStore.isLoading && publicStore.puzzles.isEmpty {
                        ProgressView("加载中…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if publicStore.puzzles.isEmpty {
                        emptyState
                    } else {
                        List(publicStore.puzzles, selection: $selectedPuzzle) { puzzle in
                            PuzzleRow(puzzle: puzzle).tag(puzzle)
                        }
                        .listStyle(.plain)
                        .refreshable { await publicStore.refresh() }
                        .scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $selectedPuzzle) { puzzle in
                    GameView(
                        puzzle: puzzle,
                        claudeConfig: makeClaudeConfig(),
                        recordStore: recordStore,
                        reviewConfig: makeReviewConfig(),
                        isPublicPuzzle: true
                    )
                    .id(puzzle.id)
                }
                .task { await publicStore.fetchIfNeeded() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("广场暂时没有题目")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 历史 Tab

struct HistoryTab: View {

    @Bindable var recordStore: GameRecordStore
    @Bindable var store: PuzzleStore
    let makeReviewConfig: () -> ReviewService.Config

    @State private var selectedRecord: GameRecord? = nil

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: "历史")
            Divider()
            NavigationStack {
                HistorySidebarList(
                    recordStore: recordStore,
                    selectedRecord: $selectedRecord
                )
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $selectedRecord) { record in
                    HistoryDetailView(
                        record: record,
                        reviewConfig: makeReviewConfig(),
                        recordStore: recordStore,
                        puzzleStore: store
                    )
                    .id(record.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 联机 Tab

struct RoomTab: View {

    @Environment(RoomService.self) private var roomService
    var publicStore: PublicPuzzleStore
    @Bindable var puzzleStore: PuzzleStore

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: "联机")
            Divider()
            NavigationStack {
                // Two mutually-exclusive states:
                //  - No room joined → RoomSidebarView (create / join entry)
                //  - Room joined    → MultiplayerDetailView (lobby / round /
                //                     finished, driven by room.status)
                Group {
                    if roomService.room == nil {
                        RoomSidebarView()
                    } else {
                        MultiplayerDetailView(
                            publicStore: publicStore,
                            puzzleStore: puzzleStore
                        )
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#endif  // !os(macOS)

