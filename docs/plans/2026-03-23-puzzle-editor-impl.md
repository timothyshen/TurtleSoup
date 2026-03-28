# 出题工作台 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 macOS SwiftUI app 中添加出题工作台：Sidebar 顶部 Tab 切换，用户可新建/编辑/删除自制题目，数据持久化到 UserDefaults。

**Architecture:** 新增 `PuzzleStore`（@Observable + UserDefaults）管理用户题目；`RootView` 持有 `sidebarTab` / `editingPuzzle` 状态；`SidebarView` 顶部 Segmented Picker 切换题库/出题；Detail 区根据 Tab 渲染 `GameView` 或 `PuzzleEditorView`。

**Tech Stack:** SwiftUI, Swift 5.9, @Observable, UserDefaults + JSONCoder, XCTest（单元测试仅针对 PuzzleStore）

---

### Task 1: PuzzleStore — 数据层

**Files:**
- Create: `TurtleSoup/PuzzleStore.swift`
- Create: `TurtleSoupTests/PuzzleStoreTests.swift`

**Step 1: 写失败测试**

在 `TurtleSoupTests/PuzzleStoreTests.swift` 写：

```swift
import XCTest
@testable import TurtleSoup

final class PuzzleStoreTests: XCTestCase {

    private let testKey = "user_puzzles_test"
    private var store: PuzzleStore!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: testKey)
        store = PuzzleStore(key: testKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testKey)
        super.tearDown()
    }

    func testSaveNewPuzzle() {
        let p = makePuzzle(title: "测试题")
        store.save(p)
        XCTAssertEqual(store.puzzles.count, 1)
        XCTAssertEqual(store.puzzles[0].title, "测试题")
    }

    func testSaveUpdatesExisting() {
        var p = makePuzzle(title: "旧标题")
        store.save(p)
        p.title = "新标题"
        store.save(p)
        XCTAssertEqual(store.puzzles.count, 1)
        XCTAssertEqual(store.puzzles[0].title, "新标题")
    }

    func testDelete() {
        let p = makePuzzle(title: "删除我")
        store.save(p)
        store.delete(p)
        XCTAssertTrue(store.puzzles.isEmpty)
    }

    func testPersistence() {
        let p = makePuzzle(title: "持久化")
        store.save(p)
        let store2 = PuzzleStore(key: testKey)
        XCTAssertEqual(store2.puzzles.count, 1)
        XCTAssertEqual(store2.puzzles[0].title, "持久化")
    }

    // MARK: - Helper
    private func makePuzzle(title: String) -> Puzzle {
        Puzzle(id: UUID(), title: title, difficulty: .easy,
               scenario: "汤面", answer: "汤底", hint: nil,
               author: "测试", playCount: 0)
    }
}
```

**Step 2: 运行测试，确认失败**

在 Xcode 中 Cmd+U，预期：编译失败（`PuzzleStore` 不存在）。

**Step 3: 实现 PuzzleStore**

创建 `TurtleSoup/PuzzleStore.swift`：

```swift
import Foundation
import Observation

@Observable
final class PuzzleStore {

    private(set) var puzzles: [Puzzle] = []
    private let key: String

    init(key: String = "user_puzzles") {
        self.key = key
        load()
    }

    func save(_ puzzle: Puzzle) {
        if let i = puzzles.firstIndex(where: { $0.id == puzzle.id }) {
            puzzles[i] = puzzle
        } else {
            puzzles.append(puzzle)
        }
        persist()
    }

    func delete(_ puzzle: Puzzle) {
        puzzles.removeAll { $0.id == puzzle.id }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Puzzle].self, from: data)
        else { return }
        puzzles = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(puzzles) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
```

**Step 4: 运行测试，确认全部通过**

Cmd+U，预期：4 个测试全部 PASS。

**Step 5: Commit**

```bash
git add TurtleSoup/PuzzleStore.swift TurtleSoupTests/PuzzleStoreTests.swift
git commit -m "feat: add PuzzleStore with UserDefaults persistence"
```

---

### Task 2: RootView — 新增 Tab 状态

**Files:**
- Modify: `TurtleSoup/RootView.swift`

**Step 1: 添加 SidebarTab 枚举和状态**

在文件顶部（`import SwiftUI` 之后、`struct RootView` 之前）加：

```swift
enum SidebarTab { case library, editor }
```

在 `RootView` body 之前加：

```swift
@State private var sidebarTab: SidebarTab = .library
@State private var editingPuzzle: Puzzle? = nil
@State private var columnVisibility = NavigationSplitViewVisibility.all
@State private var store = PuzzleStore()
```

**Step 2: 更新 NavigationSplitView**

将现有 `NavigationSplitView` 改为：

```swift
var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
        SidebarView(
            selectedPuzzle: $selectedPuzzle,
            columnVisibility: $columnVisibility,
            sidebarTab: $sidebarTab,
            editingPuzzle: $editingPuzzle,
            store: store
        )
    } detail: {
        switch sidebarTab {
        case .library:
            if let puzzle = selectedPuzzle {
                GameView(puzzle: puzzle, apiKey: apiKey)
                    .id(puzzle.id)
            } else {
                EmptyDetailView()
            }
        case .editor:
            PuzzleEditorView(puzzle: editingPuzzle, store: store)
                .id(editingPuzzle?.id)
        }
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 900, minHeight: 600)
}
```

注意：`selectedPuzzle` 已有，`columnVisibility` 从 SidebarView 移到 RootView。

**Step 3: 确认编译（先不管 SidebarView/PuzzleEditorView 报错）**

这一步会有编译错误，正常，Task 3/4 会修复。

**Step 4: Commit（等 Task 3 完成后一起提交）**

---

### Task 3: SidebarView — 顶部 Tab + 出题列表

**Files:**
- Modify: `TurtleSoup/SidebarView.swift`

**Step 1: 更新 SidebarView 签名**

将现有属性替换为：

```swift
struct SidebarView: View {

    @Binding var selectedPuzzle: Puzzle?
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var sidebarTab: SidebarTab
    @Binding var editingPuzzle: Puzzle?
    var store: PuzzleStore

    @AppStorage("claude_api_key") private var apiKey = ""
    @State private var searchText = ""
    @State private var difficultyFilter: Puzzle.Difficulty? = nil
```

**Step 2: 更新 body**

```swift
var body: some View {
    VStack(spacing: 0) {
        // Tab 切换
        Picker("", selection: $sidebarTab) {
            Text("题库").tag(SidebarTab.library)
            Text("出题").tag(SidebarTab.editor)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)

        Divider()

        // 内容区
        switch sidebarTab {
        case .library:
            libraryContent
        case .editor:
            editorContent
        }

        Divider()

        apiKeyFooter
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
    .navigationTitle("🐢 海龟汤")
    .frame(minWidth: 240)
}
```

**Step 3: 提取 libraryContent**

把原有的 filterBar + List 包成 computed var：

```swift
private var libraryContent: some View {
    VStack(spacing: 0) {
        filterBar
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        Divider()
        List(filtered, selection: $selectedPuzzle) { puzzle in
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
    .searchable(text: $searchText, placement: .sidebar, prompt: "搜索谜题")
}
```

**Step 4: 添加 editorContent**

```swift
private var editorContent: some View {
    VStack(spacing: 0) {
        Button(action: {
            editingPuzzle = nil
            withAnimation { columnVisibility = .detailOnly }
        }) {
            Label("新建题目", systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(12)

        Divider()

        if store.puzzles.isEmpty {
            Spacer()
            Text("还没有自制题目")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        } else {
            List(store.puzzles, id: \.id, selection: $editingPuzzle) { puzzle in
                PuzzleRow(puzzle: puzzle)
                    .tag(puzzle as Puzzle?)
            }
            .listStyle(.sidebar)
            .onChange(of: editingPuzzle) {
                if editingPuzzle != nil {
                    withAnimation { columnVisibility = .detailOnly }
                }
            }
        }
    }
}
```

**Step 5: 编译确认 SidebarView 无报错**

**Step 6: Commit（连同 Task 2 一起）**

```bash
git add TurtleSoup/RootView.swift TurtleSoup/SidebarView.swift
git commit -m "feat: add sidebar tab switcher for puzzle editor"
```

---

### Task 4: PuzzleEditorView — 出题表单

**Files:**
- Create: `TurtleSoup/PuzzleEditorView.swift`

**Step 1: 创建文件**

```swift
import SwiftUI

struct PuzzleEditorView: View {

    let puzzle: Puzzle?   // nil = 新建
    let store: PuzzleStore

    @State private var title = ""
    @State private var difficulty = Puzzle.Difficulty.medium
    @State private var scenario = ""
    @State private var answer = ""
    @State private var hint = ""
    @State private var author = ""

    @State private var showDeleteConfirm = false
    @State private var validationErrors: Set<Field> = []

    enum Field { case title, scenario, answer }

    var isEditing: Bool { puzzle != nil }

    init(puzzle: Puzzle?, store: PuzzleStore) {
        self.puzzle = puzzle
        self.store = store
        if let p = puzzle {
            _title      = State(initialValue: p.title)
            _difficulty = State(initialValue: p.difficulty)
            _scenario   = State(initialValue: p.scenario)
            _answer     = State(initialValue: p.answer)
            _hint       = State(initialValue: p.hint ?? "")
            _author     = State(initialValue: p.author)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 标题
                fieldSection(label: "题目标题 *", error: validationErrors.contains(.title)) {
                    TextField("简洁命名，吸引点击（≤40字）", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .overlay(errorBorder(validationErrors.contains(.title)))
                    charCount(title.count, max: 40)
                }

                // 难度
                fieldSection(label: "难度 *") {
                    Picker("难度", selection: $difficulty) {
                        ForEach(Puzzle.Difficulty.allCases, id: \.self) { d in
                            Text(d.rawValue).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // 汤面
                fieldSection(label: "汤面 *（玩家可见）", error: validationErrors.contains(.scenario)) {
                    TextEditor(text: $scenario)
                        .frame(minHeight: 100)
                        .font(.body)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(validationErrors.contains(.scenario) ? Color.red : Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    charCount(scenario.count, max: 500, min: 20)
                }

                // 汤底
                fieldSection(label: "汤底 *（仅注入 AI，玩家不可见）", error: validationErrors.contains(.answer)) {
                    TextEditor(text: $answer)
                        .frame(minHeight: 140)
                        .font(.body)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(validationErrors.contains(.answer) ? Color.red : Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    charCount(answer.count, max: 2000, min: 50)
                }

                // 提示（选填）
                fieldSection(label: "提示（选填）") {
                    TextField("玩家卡关时的提示（≤100字）", text: $hint)
                        .textFieldStyle(.roundedBorder)
                    charCount(hint.count, max: 100)
                }

                // 作者
                fieldSection(label: "作者署名（选填）") {
                    TextField("默认匿名（≤20字）", text: $author)
                        .textFieldStyle(.roundedBorder)
                    charCount(author.count, max: 20)
                }

                // 操作按钮
                HStack {
                    if isEditing {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("删除题目", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button("保存") {
                        submit()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .navigationTitle(isEditing ? "编辑题目" : "新建题目")
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let p = puzzle { store.delete(p) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
        }
    }

    // MARK: - Submit

    private func submit() {
        validationErrors = []
        if title.isEmpty || title.count > 40    { validationErrors.insert(.title) }
        if scenario.count < 20 || scenario.count > 500 { validationErrors.insert(.scenario) }
        if answer.count < 50 || answer.count > 2000  { validationErrors.insert(.answer) }
        guard validationErrors.isEmpty else { return }

        let p = Puzzle(
            id: puzzle?.id ?? UUID(),
            title: title,
            difficulty: difficulty,
            scenario: scenario,
            answer: answer,
            hint: hint.isEmpty ? nil : hint,
            author: author.isEmpty ? "匿名" : author,
            playCount: puzzle?.playCount ?? 0
        )
        store.save(p)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func fieldSection<Content: View>(
        label: String,
        error: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(error ? .red : .primary)
            content()
        }
    }

    private func errorBorder(_ show: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(show ? Color.red : Color.clear, lineWidth: 1)
    }

    @ViewBuilder
    private func charCount(_ count: Int, max: Int, min: Int? = nil) -> some View {
        let overMax = count > max
        let underMin = min.map { count < $0 } ?? false
        let showError = overMax || (underMin && count > 0)
        Text("\(count)/\(max)\(min != nil ? "（最少\(min!)字）" : "")")
            .font(.caption)
            .foregroundStyle(showError ? .red : .secondary)
    }
}
```

**Step 2: 在 Xcode 中把 PuzzleEditorView.swift 加入 Target**

文件 → 新建文件 → 或直接在 Project Navigator 右键 Add Files to TurtleSoup，确认 Target Membership 勾选 TurtleSoup。

**Step 3: 编译运行，手动测试**

- 切换到「出题」Tab → 显示「还没有自制题目」
- 点「新建题目」→ Detail 区显示空表单
- 标题留空点保存 → 标题框变红
- 填写完整信息点保存 → 左侧列表出现新题目
- 点击已有题目 → 表单回填，可编辑
- 删除确认流程

**Step 4: Commit**

```bash
git add TurtleSoup/PuzzleEditorView.swift
git commit -m "feat: add PuzzleEditorView with validation and CRUD"
```

---

### Task 5: 收尾验证

**Step 1: 验证持久化**

运行 app，新建一道题 → Cmd+Q 退出 → 重新打开 → 出题 Tab 里题目还在。

**Step 2: 验证 Notification+Extension（sidebar 展开）**

若 GameView 的 toolbar 「显示题库」按钮用了通知展开 sidebar，确认在 editor Tab 下切回 library Tab 时逻辑正常（如有问题在 RootView 的通知处理里补 `sidebarTab = .library`）。

**Step 3: 更新 CLAUDE.md**

将 `[ ] 出题工作台（UGC）` 改为 `[x]`，并在「未解决问题」里补注：
> 自制题目存于 UserDefaults，生产环境应迁移 CoreData / 后端。

**Step 4: Final Commit**

```bash
git add CLAUDE.md
git commit -m "docs: mark puzzle editor as complete"
```
