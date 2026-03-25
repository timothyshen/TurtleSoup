# 海龟汤游戏 App — macOS SwiftUI

## 项目概况
海龟汤（Lateral Thinking Puzzle）游戏，AI Agent 担任主持人，直接调 Claude API（客户端）。

## 文件结构
- Models.swift — Puzzle, Message, ClaudeAgentResponse（Puzzle 遵循 Identifiable/Codable/Hashable）
- ClaudeService.swift — actor，负责拼 system prompt + 调 /v1/messages
- GameViewModel.swift — @Observable @MainActor，驱动游戏状态
- TurtleSoupApp.swift — 入口，WindowGroup(RootView) + Settings(SettingsView)
- RootView.swift — NavigationSplitView，持有 selectedPuzzle + sidebarTab + editingPuzzle + store + newPuzzleToken
- SidebarView.swift — 顶部 segmented Tab（题库/出题），题库 Tab 含搜索/过滤（含自制题目），出题 Tab 含我的题目列表 + 新建按钮
- GameView.swift — HSplitView，左：对话，右：汤面+统计
- PuzzleEditorView.swift — 出题表单（6字段、字段校验、保存/删除）
- PuzzleStore.swift — @Observable，管理用户自制题目，CoreData 持久化（首次启动自动从 UserDefaults 迁移）
- PersistenceController.swift — 程序化 CoreData 栈（NSPersistentContainer，无 .xcdatamodeld）；含 .shared 与 .test（in-memory）两个实例
- GameRecordStore.swift — @Observable，管理游戏记录读写与统计（saveRecord/playCount/winRate）；savedRecordCount 触发 SwiftUI 刷新
- MessageBubble.swift — 气泡组件 + TypingIndicator（Task.sleep 驱动）
- SettingsView.swift — API Key 配置
- Notification+Extension.swift — Notification.Name.showSidebar

## 关键设计决策
- 汤底仅在 ClaudeService 服务端拼入 system prompt，不经任何 UI 层
- Claude API 返回严格 JSON：{"verdict": "yes|no|irr|part|win", "comment": "..."}
- @Observable 替代 ObservableObject，调用方用 @State 而非 @StateObject
- sidebar 收起：选题触发 columnVisibility = .detailOnly，GameView toolbar 发通知展开
- 出题 Tab 与题库 Tab 状态完全独立（selectedPuzzle / editingPuzzle 互不影响）
- 用户自制题目同时出现在题库列表（Puzzle.builtIn + store.puzzles 合并）
- PuzzleStore 以 @Bindable 传入子视图，确保 @Observable 变更追踪正常
- 新建题目通过 newPuzzleToken: UUID 强制 PuzzleEditorView 重建，避免 nil→nil 无法重置表单的问题
- CoreData 模型纯程序化（makeModel()），三个实体：UserPuzzleEntity / GameRecordEntity / GameMessageEntity；全程 KVC，无 NSManagedObject 子类
- GameRecord 在游戏胜利时写入；Message.Role 为 String 枚举以支持 CoreData 存储
- PersistenceController.test（in-memory）供单元测试隔离，PuzzleStore/GameRecordStore 均支持注入

## 当前进度
- [x] 题库 sidebar + 过滤/搜索
- [x] AI 游戏对话核心玩法
- [x] 解谜结算 + 汤底展示
- [x] 出题工作台（UGC）— 自制题目创建/编辑/删除，CoreData 持久化
- [x] CoreData 本地持久化（自制题目 + 游戏对话记录 + 胜率统计）
- [ ] 后端接入

## 未解决问题
- API Key 存于 UserDefaults，生产环境应迁移到 Keychain
- GameRecordStore.saveRecord 中 try? ctx.save() 静默丢弃错误，生产环境应加 os.log 或 do-catch
- 游戏记录仅在胜利时保存；未来若需「放弃」路径持久化，可给 persistRecord 加 isWon 参数

## 开发环境
- macOS 14+，Xcode 15+，SwiftUI，Swift 5.9
- Signing: Outgoing Connections (Client) 沙盒权限已开启
