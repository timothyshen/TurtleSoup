# 出题工作台设计方案

日期：2026-03-23

## 决策摘要

| 问题 | 决策 |
|------|------|
| 入口 | Sidebar 顶部 Segmented Picker（题库 / 出题） |
| 出题 Tab 布局 | 我的题目列表 + 新建按钮，Detail 区显示表单 |
| 数据存储 | UserDefaults + Codable |
| 与内置题目关系 | 完全分离，各自独立 |

## 架构

### 新增文件

- `PuzzleStore.swift` — @Observable，UserDefaults 持久化
- `PuzzleEditorView.swift` — Detail 区表单（新建/编辑）

### 修改文件

- `RootView.swift` — 新增 sidebarTab / editingPuzzle 状态，传入 store
- `SidebarView.swift` — 拆分为题库和出题两个内容区，顶部 Picker 切换

## 状态设计（RootView）

```swift
@State private var sidebarTab: SidebarTab = .library
@State private var selectedPuzzle: Puzzle? = nil      // 题库 Tab
@State private var editingPuzzle: Puzzle? = nil       // 出题 Tab，nil = 新建
@State private var store = PuzzleStore()

enum SidebarTab { case library, editor }
```

## PuzzleStore

```swift
@Observable
final class PuzzleStore {
    private(set) var puzzles: [Puzzle] = []
    private let key = "user_puzzles"

    init() { load() }

    func save(_ puzzle: Puzzle)   // upsert by id
    func delete(_ puzzle: Puzzle) // removeAll by id

    private func load()    // JSONDecoder from UserDefaults
    private func persist() // JSONEncoder to UserDefaults
}
```

## PuzzleEditorView 表单字段

| 字段 | 控件 | 限制 | 必填 |
|------|------|------|------|
| 题目标题 | TextField | ≤40字 | 是 |
| 难度 | Picker segmented | 简单/中等/困难 | 是 |
| 汤面 | TextEditor | 20–500字 | 是 |
| 汤底 | TextEditor | 50–2000字 | 是 |
| 提示 | TextField | ≤100字 | 否 |
| 作者署名 | TextField | ≤20字 | 否 |

校验失败：输入框边框变红 + 底部提示文字（不弹 Alert）
删除按钮：仅编辑模式显示，带确认 Alert
