# 海龟汤游戏 App — macOS SwiftUI + Vercel Edge 代理

## 项目概况
海龟汤（Lateral Thinking Puzzle）游戏。AI 主持人由 Claude 担任。客户端 macOS app + 边缘代理 (Vercel Edge Functions / TypeScript) 两端架构。

## 文件结构

### Swift 客户端（TurtleSoup/）
**核心服务层**
- Models.swift — Puzzle, Message, ClaudeAgentResponse（Puzzle 遵循 Identifiable/Codable/Hashable）
- ClaudeService.swift — actor，调 Claude API。Transport 枚举：`.direct(apiKey:)` 或 `.proxy(baseURL:, idTokenProvider:)`。session 可注入便于测试。
- PuzzleGenerationService.swift — actor，调代理 /api/v1/generate-puzzle（AI 辅助出题）
- ReviewService.swift — actor，调代理 /api/v1/generate-review（AI 复盘）。GameReview struct 含 summary / keyMoments[] / tip。
- AuthService.swift — @Observable @MainActor。Firebase Auth：Apple Sign In + Email/Password。`getIDToken()` 供代理鉴权用。
- FirestoreService.swift / FirestoreServicing.swift — Firestore CRUD（gameRecords / puzzles / publicPuzzles），protocol 化便于 mock。

**状态层 / Store**
- GameViewModel.swift — @Observable @MainActor，驱动游戏状态。designated init 取 ClaudeService（测试用），convenience init 取 Transport（生产用）。
- PuzzleStore.swift — @Observable，用户自制题目，CoreData 持久化 + 登录后从 Firestore 拉取合并（UserDefaults 一次性迁移）
- GameRecordStore.swift — @Observable，游戏记录 + 胜率统计 + AI 复盘 (updateAIReview/review(for:))。saveRecord 用 `record.id` 而非新 UUID（重要：updateAIReview 按 id 反查）。
- PublicPuzzleStore.swift — @Observable，公共广场题目（仅读取 + 发布）
- PersistenceController.swift — 程序化 CoreData 栈。三个实体：UserPuzzleEntity / GameRecordEntity（含 aiReview 字段，JSON-encoded String）/ GameMessageEntity。.shared 与 .test 双实例。

**入口 / 视图**
- TurtleSoupApp.swift — 入口，FirebaseApp.configure() + WindowGroup(RootView) + Settings(SettingsView)
- RootView.swift — NavigationSplitView。.task(id: uid) 在登录变化时同步 records + puzzles。makeTransport/makeGeneratorConfig/makeReviewConfig 三个工厂从 @AppStorage("proxy_endpoint") 派生。
- SidebarView.swift — 顶部 segmented：题库 / 出题 / 广场
- GameView.swift — HSplitView。左：对话气泡 + 输入。右：汤面 + 统计 + 操作。answerSheet 含 AI 复盘 UI。
- PuzzleEditorView.swift — 出题表单 + AI 生成 sheet 入口
- AIPuzzleGeneratorSheet.swift — AI 出题对话框：输入 idea → 预览 → 应用到编辑器
- PublicSquareView.swift — 广场列表
- MessageBubble.swift — 气泡 + TypingIndicator（循环 caption + 3 圆点）
- SettingsView.swift — 代理 Base URL + 本地 API Key + 账号登录 (Apple/Email)
- Notification+Extension.swift — Notification.Name.showSidebar

### TypeScript 边缘代理（proxy/）
- api/health.ts — GET 健康检查
- api/v1/messages.ts — POST 透传到 api.anthropic.com/v1/messages；body 不解析，保留 forward-compat
- api/v1/generate-puzzle.ts — POST AI 辅助出题；tool_use submit_puzzle；含 3 个 few-shot examples（cache 已生效）
- api/v1/generate-review.ts — POST AI 复盘；tool_use submit_review；transcript + isWon → {summary, keyMoments[], tip}
- lib/firebase-auth.ts — Edge 兼容的 RS256 JWT 验证（jose）。Google x509 certs 按 Cache-Control max-age 缓存。
- lib/auth-middleware.ts — requireAuth(req) → AuthResult。每个保护端点首步调用。
- lib/cors.ts / lib/errors.ts — 统一 CORS + 错误信封 `{error: {code, message}}`
- test/smoke.sh — 黑盒：health + 4 个 401 网关验证

### 测试（TurtleSoupTests/）
- PuzzleStoreTests, FirestoreSyncTests — 持久化 + 同步
- PuzzleGenerationServiceTests / ClaudeServiceTests / ReviewServiceTests — service 层 MockURLProtocol
- GameViewModelTests — 核心状态机
- GameReviewPersistenceTests — JSON 编解码 + CoreData round-trip + 旧 bug regression

## 关键设计决策

**架构**
- 汤底仅在 system prompt 内传递，**不经任何 UI 层**。客户端从不持有完整汤底渲染权（除游戏结束后的 answerSheet）。
- Claude API 走代理。客户端 `Transport` 二选一：`.direct(apiKey:)` 兼容本地开发，`.proxy(baseURL:, idTokenProvider:)` 生产路径。
- AI 出题 / AI 复盘是 proxy-only 设计 —— prompt + tool schema + few-shot examples 留在服务端，可独立迭代不发版。

**模型层**
- Sonnet 4.6（model_id `claude-sonnet-4-6`）。effort 必须显式：gameplay=low、出题=medium、复盘=medium。thinking 全部 disabled。
- Prompt caching `cache_control: ephemeral`：generate-puzzle 已过 2048 阈值生效；gameplay 钩子已埋（system prompt 当前 ~400-700 tokens 静默 no-op，等加内容自动生效）。

**SwiftUI 状态**
- @Observable 替代 ObservableObject，调用方用 @State 而非 @StateObject
- store 以 @Bindable 传入子视图保证变更追踪
- 新建题目用 newPuzzleToken: UUID 强制 PuzzleEditorView 重建（解决 nil→nil 不重置）
- sidebar：选题触发 columnVisibility = .detailOnly，GameView toolbar 发通知展开

**持久化**
- CoreData 程序化模型 (makeModel)，三实体全程 KVC，无 NSManagedObject 子类
- GameRecord 在胜利或放弃时写入，isWon 标志区分；AI 复盘以 JSON String 存 `aiReview` 字段，schema flat 便于未来扩展无需迁移
- `record.id` 客户端生成、直接写入 CoreData id 列、用作 Firestore 文档 ID —— 三方一致

**Auth + 同步**
- AuthService 是 @MainActor 单例（@Environment 注入）
- RootView.task(id: uid) 在 uid 变化时双向同步 records + puzzles
- 同 Firestore 文档 id（record.id.uuidString）避免精度冲突
- saveRecord dedup 命中时 backfill aiReview，支持跨设备复盘同步

## 当前进度
- [x] 题库 sidebar + 过滤/搜索
- [x] AI 游戏对话核心玩法
- [x] 解谜结算 + 汤底展示
- [x] 出题工作台（UGC）— 自制题目创建/编辑/删除，CoreData 持久化
- [x] CoreData 本地持久化（自制题目 + 游戏对话记录 + 胜率统计）
- [x] 放弃路径（isWon:false 记录）
- [x] Firebase Auth：Apple + Email/Password
- [x] Firestore 同步：gameRecords + puzzles + publicPuzzles 双向
- [x] 公共广场
- [x] Vercel 代理：/v1/messages + ID Token 鉴权
- [x] AI 辅助出题（few-shot examples + tool_use）
- [x] AI 复盘（结构化 key_moments + tip）
- [x] Sonnet 4.6 升级 + prompt caching
- [x] 「打字中」UX 强化（循环 caption + send button spinner）
- [ ] 微信登录（资质待查；混合方案：wx → Firebase Custom Token）
- [ ] 部署 + 端到端联调（Vercel + Firebase 接入待用户手动完成）

## 未解决问题
- API Key 存于 UserDefaults，生产环境应迁移到 Keychain（或彻底切代理路径后删除 .direct 模式）
- 公共广场 playCount 当前只读不写，应在开始一局公共题时 `FieldValue.increment(1)`
- syncFromFirestore 仅写本地不写远端（避免环路），但下次同步时本地 messages 是空的（远端不存 messages）—— 多设备查看历史对话只看得到最后玩的那台
- Firebase SDK 在 Xcode 工程里**仍未接入**：需手动 Add Package Dependency + GoogleService-Info.plist + Enable Auth/Firestore in console + Sign In with Apple capability（详见 docs/plans/2026-03-28-backend-integration.md Task 3）

## 开发环境
- macOS 14+，Xcode 16+，SwiftUI，Swift 5.9+
- Xcode 工程使用 PBXFileSystemSynchronizedRootGroup（文件系统同步组，文件加入 TurtleSoup/ 自动入工程）
- Signing: Outgoing Connections (Client) + Sign In with Apple 沙盒权限已开启
- 代理：Node 20+ on Vercel Edge runtime；本地 `cd proxy && npx tsc --noEmit` 验证

## 部署指引（仅供参考，等用户操作）
1. **Firebase**（详见 docs/plans/2026-03-28-backend-integration.md）
   - File → Add Package Dependencies → firebase-ios-sdk
   - Firebase Console 建项目 + 下载 GoogleService-Info.plist 拖入 TurtleSoup/
   - 启用 Auth providers + Firestore + 贴 docs/firestore-rules.md 的规则
   - 加 Sign In with Apple capability
2. **Vercel 代理**
   - `cd proxy && vercel login && vercel link && vercel --prod`
   - Dashboard 设环境变量：ANTHROPIC_API_KEY + FIREBASE_PROJECT_ID
   - 跑 `proxy/test/smoke.sh https://xxx.vercel.app` 验证 5 个 case 全过
3. **客户端**
   - Settings → 代理 Base URL 填 `https://xxx.vercel.app`
   - 登录 Apple 或 Email
   - 玩一局 + 试一次 AI 生成 + 试一次 AI 复盘
