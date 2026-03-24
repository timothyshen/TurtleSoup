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
- PuzzleStore.swift — @Observable，管理用户自制题目，UserDefaults + Codable 持久化
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

## 当前进度
- [x] 题库 sidebar + 过滤/搜索
- [x] AI 游戏对话核心玩法
- [x] 解谜结算 + 汤底展示
- [x] 出题工作台（UGC）— 自制题目创建/编辑/删除，UserDefaults 持久化
- [ ] CoreData / SwiftData 本地持久化（当前用 UserDefaults，大量数据时需迁移）
- [ ] 后端接入

## 未解决问题
- API Key 存于 UserDefaults，生产环境应迁移到 Keychain
- PuzzleStore 用 UserDefaults 存储全量 JSON，题目多时每次写入开销较大，后续应迁移到文件系统或 SwiftData

## 开发环境
- macOS 14+，Xcode 15+，SwiftUI，Swift 5.9
- Signing: Outgoing Connections (Client) 沙盒权限已开启
