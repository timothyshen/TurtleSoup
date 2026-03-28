# CoreData 本地持久化 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** 将自制题目存储从 UserDefaults 迁移到 CoreData，并新增完整游戏记录（对话历史、用时、输赢）及统计信息（游玩次数、胜率）。

**Architecture:**
- 纯程序化 `NSManagedObjectModel`（不需要 .xcdatamodeld 文件）；三个实体：`UserPuzzleEntity`、`GameRecordEntity`、`GameMessageEntity`；`GameRecordEntity ←->> GameMessageEntity` 关联关系。
- `PersistenceController` 单例管理 NSPersistentContainer；`PuzzleStore` 改用 CoreData 读写，并在首次启动时从 UserDefaults 一次性迁移数据；`GameRecordStore` 新 @Observable 管理游戏记录与统计；`GameViewModel` 接收 `GameRecordStore`，游戏结束时持久化。

**Tech Stack:** Swift 5.9, CoreData, @Observable (Observation framework), macOS 14+, Xcode 15+

---

## 背景与约束

- 项目已使用 `PBXFileSystemSynchronizedRootGroup`，在 `TurtleSoup/` 目录下新建 `.swift` 文件无需修改 Xcode 项目文件，Xcode 自动发现。
- `Puzzle` struct 已遵循 `Identifiable/Codable/Hashable`，`Message` struct 已有 `id, role, text, verdict, timestamp`。
- `PuzzleStore` 当前 API（`save`, `delete`, `puzzles`）不变，调用方无需修改。
- 不引入 NSManagedObject 子类，全程用 KVC（`value(forKey:) / setValue(_:forKey:)`）。

---

## Task 1: PersistenceController — 程序化 CoreData 栈

**Files:**
- Create: `TurtleSoup/PersistenceController.swift`

### 步骤

**Step 1: 创建文件**

```swift
// TurtleSoup/PersistenceController.swift
import CoreData

final class PersistenceController {

    static let shared = PersistenceController()

    let container: NSPersistentContainer
    var ctx: NSManagedObjectContext { container.viewContext }

    private init(inMemory: Bool = false) {
        container = NSPersistentContainer(
            name: "TurtleSoup",
            managedObjectModel: Self.makeModel()
        )
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { _, error in
            if let error { fatalError("CoreData load error: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - Programmatic model (no .xcdatamodeld needed)

    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        // ── UserPuzzleEntity ──────────────────────────────────────────────
        let puzzleE = entity("UserPuzzleEntity", attrs: [
            attr("id",         .UUIDAttributeType,     optional: false),
            attr("title",      .stringAttributeType,   optional: false),
            attr("difficulty", .stringAttributeType,   optional: false),
            attr("scenario",   .stringAttributeType,   optional: false),
            attr("answer",     .stringAttributeType,   optional: false),
            attr("hint",       .stringAttributeType,   optional: true),
            attr("author",     .stringAttributeType,   optional: false),
            attr("createdAt",  .dateAttributeType,     optional: false),
        ])

        // ── GameRecordEntity ──────────────────────────────────────────────
        let recordE = entity("GameRecordEntity", attrs: [
            attr("id",            .UUIDAttributeType,     optional: false),
            attr("puzzleID",      .UUIDAttributeType,     optional: false),
            attr("puzzleTitle",   .stringAttributeType,   optional: false),
            attr("startedAt",     .dateAttributeType,     optional: false),
            attr("endedAt",       .dateAttributeType,     optional: true),
            attr("isWon",         .booleanAttributeType,  optional: false),
            attr("questionCount", .integer32AttributeType,optional: false),
        ])

        // ── GameMessageEntity ─────────────────────────────────────────────
        let messageE = entity("GameMessageEntity", attrs: [
            attr("id",        .UUIDAttributeType,   optional: false),
            attr("role",      .stringAttributeType, optional: false),
            attr("text",      .stringAttributeType, optional: false),
            attr("verdict",   .stringAttributeType, optional: true),
            attr("timestamp", .dateAttributeType,   optional: false),
        ])

        // ── Relationship: record <-->> messages ───────────────────────────
        let recToMsg = rel("messages",  dest: messageE, toMany: true,  delete: .cascadeDeleteRule)
        let msgToRec = rel("record",    dest: recordE,  toMany: false, delete: .nullifyDeleteRule)
        recToMsg.inverseRelationship = msgToRec
        msgToRec.inverseRelationship = recToMsg
        recordE.properties  += [recToMsg]
        messageE.properties += [msgToRec]

        model.entities = [puzzleE, recordE, messageE]
        return model
    }

    // MARK: - Helpers

    private static func entity(_ name: String, attrs: [NSAttributeDescription]) -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = name
        e.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        e.properties = attrs
        return e
    }

    private static func attr(_ name: String, _ type: NSAttributeType, optional: Bool) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        a.isOptional = optional
        return a
    }

    private static func rel(_ name: String, dest: NSEntityDescription, toMany: Bool, delete: NSDeleteRule) -> NSRelationshipDescription {
        let r = NSRelationshipDescription()
        r.name = name
        r.destinationEntity = dest
        r.isOptional = true
        r.deleteRule = delete
        r.minCount = 0
        r.maxCount = toMany ? 0 : 1
        return r
    }

    // MARK: - Save helper

    func save() {
        guard ctx.hasChanges else { return }
        try? ctx.save()
    }
}
```

**Step 2: 编译验证**

在 Xcode 中 Build（⌘B），确认无错误。CoreData 框架无需手动 link（macOS 自动包含）。

**Step 3: Commit**

```bash
git add TurtleSoup/PersistenceController.swift
git commit -m "feat: add programmatic CoreData stack (PersistenceController)"
```

---

## Task 2: PuzzleStore 迁移到 CoreData + UserDefaults 一次性迁移

**Files:**
- Modify: `TurtleSoup/PuzzleStore.swift`

### 背景

当前 `PuzzleStore` 使用 `UserDefaults` 存储 `[Puzzle]`（key = `"user_puzzles"`）。迁移策略：首次启动检查 `UserDefaults` 是否有旧数据 → 有则导入 CoreData → 删除 UserDefaults 数据 → 设置迁移标记。

### 步骤

**Step 1: 替换 PuzzleStore.swift 全部内容**

```swift
// TurtleSoup/PuzzleStore.swift
import Foundation
import CoreData
import Observation

@Observable
final class PuzzleStore {

    private(set) var puzzles: [Puzzle] = []
    private let pc = PersistenceController.shared

    init() {
        migrateFromUserDefaultsIfNeeded()
        fetch()
    }

    // MARK: - Public API (unchanged)

    func save(_ puzzle: Puzzle) {
        let ctx = pc.ctx
        // 查找现有对象或新建
        let obj = findOrCreate(id: puzzle.id, in: ctx)
        fill(obj, from: puzzle)
        pc.save()
        fetch()
    }

    func delete(_ puzzle: Puzzle) {
        let ctx = pc.ctx
        if let obj = findOrCreate(id: puzzle.id, in: ctx) as NSManagedObject?,
           obj.objectID.isTemporaryID == false {
            // 重新 fetch 以确保对象属于当前 context
            let fetchReq = NSFetchRequest<NSManagedObject>(entityName: "UserPuzzleEntity")
            fetchReq.predicate = NSPredicate(format: "id == %@", puzzle.id as CVarArg)
            fetchReq.fetchLimit = 1
            if let found = try? ctx.fetch(fetchReq).first {
                ctx.delete(found)
                pc.save()
            }
        }
        fetch()
    }

    // MARK: - Private

    private func fetch() {
        let req = NSFetchRequest<NSManagedObject>(entityName: "UserPuzzleEntity")
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let objects = (try? pc.ctx.fetch(req)) ?? []
        puzzles = objects.compactMap { toPuzzle($0) }
    }

    private func findOrCreate(id: UUID, in ctx: NSManagedObjectContext) -> NSManagedObject {
        let req = NSFetchRequest<NSManagedObject>(entityName: "UserPuzzleEntity")
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        if let found = try? ctx.fetch(req).first { return found }
        let obj = NSEntityDescription.insertNewObject(forEntityName: "UserPuzzleEntity", into: ctx)
        obj.setValue(id, forKey: "id")
        obj.setValue(Date(), forKey: "createdAt")
        return obj
    }

    private func fill(_ obj: NSManagedObject, from p: Puzzle) {
        obj.setValue(p.title,           forKey: "title")
        obj.setValue(p.difficulty.rawValue, forKey: "difficulty")
        obj.setValue(p.scenario,        forKey: "scenario")
        obj.setValue(p.answer,          forKey: "answer")
        obj.setValue(p.hint,            forKey: "hint")
        obj.setValue(p.author,          forKey: "author")
    }

    private func toPuzzle(_ obj: NSManagedObject) -> Puzzle? {
        guard
            let id        = obj.value(forKey: "id")         as? UUID,
            let title     = obj.value(forKey: "title")      as? String,
            let diffStr   = obj.value(forKey: "difficulty") as? String,
            let diff      = Puzzle.Difficulty(rawValue: diffStr),
            let scenario  = obj.value(forKey: "scenario")   as? String,
            let answer    = obj.value(forKey: "answer")      as? String,
            let author    = obj.value(forKey: "author")      as? String
        else { return nil }

        let hint = obj.value(forKey: "hint") as? String
        return Puzzle(id: id, title: title, difficulty: diff,
                      scenario: scenario, answer: answer,
                      hint: hint, author: author, playCount: 0)
    }

    // MARK: - UserDefaults → CoreData 一次性迁移

    private func migrateFromUserDefaultsIfNeeded() {
        let migratedKey = "puzzle_store_coredata_migrated"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }

        let udKey = "user_puzzles"
        if let data = UserDefaults.standard.data(forKey: udKey),
           let old = try? JSONDecoder().decode([Puzzle].self, from: data) {
            let ctx = pc.ctx
            for p in old {
                let obj = NSEntityDescription.insertNewObject(
                    forEntityName: "UserPuzzleEntity", into: ctx)
                obj.setValue(p.id,                    forKey: "id")
                obj.setValue(p.title,                 forKey: "title")
                obj.setValue(p.difficulty.rawValue,   forKey: "difficulty")
                obj.setValue(p.scenario,              forKey: "scenario")
                obj.setValue(p.answer,                forKey: "answer")
                obj.setValue(p.hint,                  forKey: "hint")
                obj.setValue(p.author,                forKey: "author")
                obj.setValue(Date(),                  forKey: "createdAt")
            }
            pc.save()
            UserDefaults.standard.removeObject(forKey: udKey)
        }
        UserDefaults.standard.set(true, forKey: migratedKey)
    }
}
```

**Step 2: 编译验证**（⌘B），确认无错误

**Step 3: 手动测试**
1. 运行 App，进入「出题」Tab，新建一道题目，保存
2. 退出 App，重新运行，确认题目还在

**Step 4: Commit**

```bash
git add TurtleSoup/PuzzleStore.swift
git commit -m "feat: migrate PuzzleStore from UserDefaults to CoreData with one-time migration"
```

---

## Task 3: GameRecordStore — 游戏记录存取与统计

**Files:**
- Create: `TurtleSoup/GameRecordStore.swift`

### 职责

- `saveRecord(_:)` — 保存一局游戏（完整消息列表 + 结果）
- `playCount(for:)` — 某道题被玩的总次数
- `winRate(for:)` — 某道题的胜率（0.0–1.0）
- `records(for:)` — 某道题的所有历史记录

### 步骤

**Step 1: 创建 GameRecordStore.swift**

```swift
// TurtleSoup/GameRecordStore.swift
import CoreData
import Observation

/// 一局游戏的完整快照，用于持久化
struct GameRecord {
    let puzzleID: UUID
    let puzzleTitle: String
    let startedAt: Date
    let endedAt: Date
    let isWon: Bool
    let questionCount: Int
    let messages: [Message]   // Message 来自 Models.swift
}

@Observable
final class GameRecordStore {

    private let pc = PersistenceController.shared

    // MARK: - Write

    func saveRecord(_ record: GameRecord) {
        let ctx = pc.ctx

        // 防重：同一 puzzleID + startedAt 不重复写
        let dup = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        dup.predicate = NSPredicate(format: "puzzleID == %@ AND startedAt == %@",
                                    record.puzzleID as CVarArg,
                                    record.startedAt as NSDate)
        dup.fetchLimit = 1
        guard (try? ctx.fetch(dup).first) == nil else { return }

        // 写 GameRecordEntity
        let recObj = NSEntityDescription.insertNewObject(
            forEntityName: "GameRecordEntity", into: ctx)
        recObj.setValue(UUID(),                forKey: "id")
        recObj.setValue(record.puzzleID,       forKey: "puzzleID")
        recObj.setValue(record.puzzleTitle,    forKey: "puzzleTitle")
        recObj.setValue(record.startedAt,      forKey: "startedAt")
        recObj.setValue(record.endedAt,        forKey: "endedAt")
        recObj.setValue(record.isWon,          forKey: "isWon")
        recObj.setValue(Int32(record.questionCount), forKey: "questionCount")

        // 写 GameMessageEntity（关联）
        var msgSet = Set<NSManagedObject>()
        for msg in record.messages {
            let msgObj = NSEntityDescription.insertNewObject(
                forEntityName: "GameMessageEntity", into: ctx)
            msgObj.setValue(msg.id,             forKey: "id")
            msgObj.setValue(msg.role.rawValue,  forKey: "role")
            msgObj.setValue(msg.text,           forKey: "text")
            msgObj.setValue(msg.verdict?.rawValue, forKey: "verdict")
            msgObj.setValue(msg.timestamp,      forKey: "timestamp")
            msgObj.setValue(recObj,             forKey: "record")
            msgSet.insert(msgObj)
        }
        recObj.setValue(msgSet, forKey: "messages")

        pc.save()
    }

    // MARK: - Read / Stats

    func playCount(for puzzleID: UUID) -> Int {
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.predicate = NSPredicate(format: "puzzleID == %@", puzzleID as CVarArg)
        return (try? pc.ctx.count(for: req)) ?? 0
    }

    func winRate(for puzzleID: UUID) -> Double {
        let total = playCount(for: puzzleID)
        guard total > 0 else { return 0 }
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.predicate = NSPredicate(format: "puzzleID == %@ AND isWon == YES", puzzleID as CVarArg)
        let wins = (try? pc.ctx.count(for: req)) ?? 0
        return Double(wins) / Double(total)
    }

    func records(for puzzleID: UUID) -> [NSManagedObject] {
        let req = NSFetchRequest<NSManagedObject>(entityName: "GameRecordEntity")
        req.predicate = NSPredicate(format: "puzzleID == %@", puzzleID as CVarArg)
        req.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        return (try? pc.ctx.fetch(req)) ?? []
    }
}
```

> **注意：** `Message.Role` 需要加 `rawValue` 访问，需要先把 `Role` 改为 `String` 枚举（见 Task 4 Step 1）。

**Step 2: 编译验证**（⌘B）

**Step 3: Commit**

```bash
git add TurtleSoup/GameRecordStore.swift
git commit -m "feat: add GameRecordStore for game history and statistics"
```

---

## Task 4: Models + GameViewModel — 持久化游戏记录

**Files:**
- Modify: `TurtleSoup/Models.swift`（`Message.Role` 改为 rawValue String 枚举）
- Modify: `TurtleSoup/GameViewModel.swift`（接收 `GameRecordStore`，游戏结束时保存）

### 步骤

**Step 1: Models.swift — 给 Message.Role 加 rawValue**

把 `enum Role { case user, assistant, system }` 改为：

```swift
enum Role: String {
    case user      = "user"
    case assistant = "assistant"
    case system    = "system"
}
```

同时，`Message` 需要存 `timestamp`（已有），确认不变。

**Step 2: GameViewModel.swift — 注入 GameRecordStore，游戏结束保存**

在 `GameViewModel` 中：

1. 新增属性：
```swift
private let recordStore: GameRecordStore
private let startedAt: Date = Date()
```

2. 修改 `init`：
```swift
init(puzzle: Puzzle, apiKey: String, recordStore: GameRecordStore) {
    self.puzzle = puzzle
    self.claude = ClaudeService(apiKey: apiKey)
    self.recordStore = recordStore
    self.messages = [
        Message(role: .system,
                text: "游戏开始——你可以用陈述或问句来探索真相，主持人只回答：是 / 否 / 无关 / 部分正确")
    ]
}
```

3. 在 `send()` 里，紧接 `isGameWon = true` 之后（`try? await Task.sleep...` 之前）调用：
```swift
persistRecord(isWon: true)
```

4. 新增 `persistRecord` 方法：
```swift
private func persistRecord(isWon: Bool) {
    let record = GameRecord(
        puzzleID:      puzzle.id,
        puzzleTitle:   puzzle.title,
        startedAt:     startedAt,
        endedAt:       Date(),
        isWon:         isWon,
        questionCount: questionCount,
        messages:      messages.filter { $0.role != .system }
    )
    recordStore.saveRecord(record)
}
```

**Step 3: 编译验证**（⌘B）

**Step 4: Commit**

```bash
git add TurtleSoup/Models.swift TurtleSoup/GameViewModel.swift
git commit -m "feat: persist game records to CoreData on win"
```

---

## Task 5: RootView + GameView — 历史统计显示

**Files:**
- Modify: `TurtleSoup/RootView.swift`（创建 `GameRecordStore`，传入 `GameView`）
- Modify: `TurtleSoup/GameView.swift`（`init` 接收 `recordStore`，infoPane 显示历史统计）

### 步骤

**Step 1: RootView.swift — 新增 recordStore**

```swift
@State private var recordStore = GameRecordStore()
```

传给 GameView：
```swift
GameView(puzzle: puzzle, apiKey: apiKey, recordStore: recordStore)
```

**Step 2: GameView.swift — 接收并传入 ViewModel**

修改 `init`：
```swift
init(puzzle: Puzzle, apiKey: String, recordStore: GameRecordStore) {
    _vm = State(wrappedValue: GameViewModel(puzzle: puzzle, apiKey: apiKey, recordStore: recordStore))
    _recordStore = State(wrappedValue: recordStore)
}
@State private var recordStore: GameRecordStore
```

**Step 3: GameView.swift — infoPane 加历史统计行**

在 `infoPane` 的「本局统计」`VStack` 内，`statRow(label: "出题者" ...)` 之后添加：

```swift
let total = recordStore.playCount(for: vm.puzzle.id)
let rate  = recordStore.winRate(for: vm.puzzle.id)

if total > 0 {
    Divider()
    statRow(label: "历史游玩", value: "\(total) 次")
    statRow(label: "胜率",     value: String(format: "%.0f%%", rate * 100))
}
```

> 注意：`infoPane` 是 `var body` 的一部分，`let` 声明需放在 `VStack` 的 `ViewBuilder` closure 内最顶部（Swift 5.9 支持 ViewBuilder 内的 `let`）。或抽成 computed var。

**Step 4: 编译验证** + 手动测试
1. 选一道题，完成游戏（解谜成功）
2. 关闭，重新进入同一道题
3. 右侧 infoPane 应显示「历史游玩: 1 次 / 胜率: 100%」

**Step 5: Commit**

```bash
git add TurtleSoup/RootView.swift TurtleSoup/GameView.swift
git commit -m "feat: display historical play count and win rate in GameView"
```

---

## Task 6: 收尾 — CLAUDE.md 更新

**Files:**
- Modify: `CLAUDE.md`

### 步骤

**Step 1: 更新文件结构部分**

在文件结构列表中新增：
```
- PersistenceController.swift — 程序化 CoreData 栈（NSPersistentContainer，无 .xcdatamodeld）
- GameRecordStore.swift — @Observable，管理游戏记录读写与统计（游玩次数、胜率）
```

**Step 2: 更新关键设计决策**

新增：
```
- CoreData 模型纯程序化构建（makeModel()），避免 .xcdatamodeld 文件与 Xcode 项目绑定问题
- GameRecord 在游戏胜利时写入；Message.Role 改为 String 枚举以支持 CoreData 存储
- 首次启动自动将 UserDefaults "user_puzzles" 迁移到 CoreData，迁移后删除旧数据
```

**Step 3: 更新当前进度**

```markdown
- [x] CoreData / 本地持久化（自制题目 + 游戏记录 + 胜率统计）
```

**Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for CoreData persistence implementation"
```

---

## 验收清单

- [ ] 新建自制题目 → 退出 App → 重启 → 题目仍在
- [ ] 编辑自制题目 → 退出 → 重启 → 修改已保存
- [ ] 删除自制题目 → 退出 → 重启 → 题目已消失
- [ ] 首次启动：若 UserDefaults 有旧数据，自动迁移（不重复）
- [ ] 完成一局游戏 → 再次进入同一题 → 右侧显示历史游玩次数与胜率
- [ ] 对话消息可通过 CoreData 查到（可在 `records(for:)` 调试验证）
- [ ] `⌘B` 编译无 warning/error
