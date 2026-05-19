# 海龟汤游戏 App — macOS SwiftUI + Vercel Edge 代理

## 项目概况
海龟汤（Lateral Thinking Puzzle）游戏。AI 主持人由 Claude 担任。客户端 macOS app + 边缘代理 (Vercel Edge Functions / TypeScript) 两端架构。

## 文件结构

### Swift 客户端（TurtleSoup/）
**核心服务层**
- Models.swift — Puzzle, Message (Codable + Equatable), ClaudeAgentResponse
- ClaudeService.swift — actor，调 Claude API。Transport 枚举：`.direct(apiKey:)` 或 `.proxy(baseURL:, idTokenProvider:)`。同时提供 `send()`（非流式）和 `sendStream()`（流式 + verdict early-emit）。session 可注入便于测试。
- PuzzleGenerationService.swift — actor，调代理 /api/v1/generate-puzzle。`generate()`（非流式）+ `generateStream()`（progress + complete events）双轨。
- ReviewService.swift — actor，调代理 /api/v1/generate-review。同样双轨。GameReview 含 summary / keyMoments[] / tip。
- ProxyStreamParser.swift — 共享 SSE 解析器。从 URLSession.AsyncBytes 读 event/data 块，产出 ProxyStreamEvent (progress/complete/error)。PuzzleGenerationService 和 ReviewService 流式都用它。
- AuthService.swift — @Observable @MainActor。Firebase Auth：Apple Sign In + Email/Password。`getIDToken()` 供代理鉴权用。
- FirestoreService.swift / FirestoreServicing.swift — Firestore CRUD（gameRecords / puzzles / publicPuzzles）+ `incrementPublicPlayCount(puzzleID:)` 写 publicPuzzles。protocol 化便于 mock。

**状态层 / Store**
- GameViewModel.swift — @Observable @MainActor，驱动游戏状态机 + streaming consumption（占位 message + verdict-early 替换）+ AI 复盘流式 progress。designated init 取 ClaudeService（测试用），convenience init 取 Transport（生产用），含 `isPublicPuzzle` 标志驱动 playCount 回写。
- PuzzleStore.swift — @Observable，用户自制题目，CoreData 持久化 + 登录后从 Firestore 拉取合并（UserDefaults 一次性迁移）
- GameRecordStore.swift — @Observable，游戏记录 + 胜率统计 + AI 复盘 (updateAIReview/review(for:)) + `incrementPublicPlayCount` + `messages(for:)` 读历史 transcript。saveRecord 用 `record.id` 而非新 UUID。dedup 命中时回填 aiReview 和 transcript（跨设备同步）。
- PublicPuzzleStore.swift — @Observable，公共广场题目（仅读取 + 发布）
- PersistenceController.swift — 程序化 CoreData 栈。三个实体：UserPuzzleEntity / GameRecordEntity（含 aiReview JSON-encoded String 字段）/ GameMessageEntity。.shared 与 .test 双实例。

**入口 / 视图**
- TurtleSoupApp.swift — 入口，FirebaseApp.configure() + WindowGroup(RootView) + Settings(SettingsView)
- RootView.swift — NavigationSplitView。.task(id: uid) 在登录变化时同步 records + puzzles。makeTransport/makeGeneratorConfig/makeReviewConfig 三个工厂从 @AppStorage("proxy_endpoint") 派生。GameView 接 isPublicPuzzle = (sidebarTab == .square)。
- SidebarView.swift — 顶部 segmented：题库 / 出题 / 广场
- GameView.swift — HSplitView。左：对话气泡（流式 verdict 早出 + 占位填充）+ 输入（loading spinner）。右：汤面 + 统计 + 操作。answerSheet 含 AI 复盘 UI（含流式 progress checklist）。
- PuzzleEditorView.swift — 出题表单 + AI 生成 sheet 入口
- AIPuzzleGeneratorSheet.swift — AI 出题对话框：四态（input → progressPane checklist → previewPane → proxyMissingNotice），流式逐字段填充
- PublicSquareView.swift — 广场列表
- MessageBubble.swift — 气泡 + TypingIndicator（循环 caption + 3 圆点）
- SettingsView.swift — 代理 Base URL + 本地 API Key + 账号登录 (Apple/Email) + 「该路径不支持 AI 功能」橙色 reminder（仅在 proxy 留空但本地 key 有值时出）
- Notification+Extension.swift — Notification.Name.showSidebar

### TypeScript 边缘代理（proxy/）
- api/health.ts — GET 健康检查
- api/v1/messages.ts — POST 透传到 api.anthropic.com/v1/messages；body 不解析，SSE 也无需特殊处理（自然透传）
- api/v1/generate-puzzle.ts — POST AI 辅助出题。`stream: true` 开启 SSE 输出（progress + complete + error），否则一次性 JSON。tool_use submit_puzzle，3 个 few-shot examples（cache 已生效）
- api/v1/generate-review.ts — POST AI 复盘。同样 `stream: true` 开关。tool_use submit_review。
- lib/tool-stream.ts — FieldDetector（正则扫描 partial JSON，按 field allowlist 检测关闭）+ sseEvent/parseSSEBlock/sseBlocks helpers。puzzle 和 review 流式共享。
- lib/sse-shape.ts — 客户端看到的简化 SSE 事件 union type（progress/complete/error）
- lib/firebase-auth.ts — Edge 兼容的 RS256 JWT 验证（jose）。Google x509 certs 按 Cache-Control max-age 缓存。
- lib/auth-middleware.ts — requireAuth(req) → AuthResult。每个保护端点首步调用。
- lib/cors.ts / lib/errors.ts — 统一 CORS + 错误信封 `{error: {code, message}}`
- test/smoke.sh — 黑盒：health + 4 个 401 网关验证（含 generate-review）

### 测试（TurtleSoupTests/，~46 cases 6 个 suite）
- PuzzleStoreTests, FirestoreSyncTests — 持久化 + 同步
- PuzzleGenerationServiceTests — 非流式 + 流式（共 15 cases，含 progress 顺序断言）
- ClaudeServiceTests — 非流式 + 流式（共 15 cases，含 extractVerdict 直接测）
- ReviewServiceTests — 非流式 + 流式（共 10 cases）
- GameViewModelTests — 状态机 + 流式适配 + 公共 playCount 回写（13 cases）
- GameReviewPersistenceTests — JSON 编解码 + CoreData round-trip + 旧 bug regression（9 cases）
- TranscriptSyncTests — Message Codable + messages(for:) + dedup 回填 transcript + 50 turn size sanity（7 cases）
- TestFixtures.swift — 共享 fixture：samplePuzzle / anthropicEnvelope / anthropicSSE 系列 / proxyStreamBody/Error。修复了旧的跨文件 private 引用 bug。

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
- saveRecord dedup 命中时 backfill aiReview **和** transcript messages（多端可看完整历史对话）

**流式响应（gameplay + 出题 + 复盘 三端）**
- gameplay `/v1/messages`：代理透传 Anthropic SSE；客户端 `ClaudeService.sendStream` 边读 content_block_delta 边用 `extractVerdict` 早 emit verdict event；GameViewModel 先 append 空 assistant message 拿 placeholder id，verdict 来填 badge，complete 来填 comment text。失败时撕掉 placeholder。
- 出题 / 复盘：代理读 Anthropic SSE → `FieldDetector` 检测每个字段关闭 → 发简化 SSE 给客户端（`progress {field, value}` + `complete {payload}` + `error {code, message}`）。客户端 `ProxyStreamReader` 解析后 yield 给 service stream。
- 客户端 UI 用 progress checklist 渲染：AIPuzzleGeneratorSheet 渲染 5 个字段，answerSheet review section 渲染 summary/key_moments/tip 三行。
- 三端的非流式路径都保留作为 fallback。streaming 默认开（gameplay 永远流式；puzzle/review 由客户端 `stream:true` 标志触发）。

## 当前进度
- [x] 题库 sidebar + 过滤/搜索
- [x] AI 游戏对话核心玩法 + 流式 verdict early-emit
- [x] 解谜结算 + 汤底展示
- [x] 出题工作台（UGC）— 自制题目创建/编辑/删除，CoreData 持久化
- [x] CoreData 本地持久化（自制题目 + 游戏对话记录 + 胜率统计）
- [x] 放弃路径（isWon:false 记录）
- [x] Firebase Auth：Apple + Email/Password
- [x] Firestore 同步：gameRecords + puzzles + publicPuzzles 双向；多端 transcript blob
- [x] 公共广场（含 playCount FieldValue.increment 回写）
- [x] Vercel 代理：/v1/messages + ID Token 鉴权
- [x] AI 辅助出题（few-shot examples + tool_use + 流式 progress checklist）
- [x] AI 复盘（结构化 key_moments + tip + 流式 progress checklist）
- [x] Sonnet 4.6 升级 + prompt caching
- [x] 「打字中」UX 强化（循环 caption + send button spinner）
- [x] Settings reminder：本地 key 路径下提示用户切代理
- [ ] 部署 + 端到端联调（Vercel + Firebase 接入待用户手动完成）

**已显式 drop**：微信登录（曾考虑混合方案 wx → Firebase Custom Token，需企业资质 + 复杂扫码流，决定只走 Apple + Email/Password）

## 未解决问题
- API Key 存于 UserDefaults，生产环境应迁移到 Keychain（或彻底切代理路径后删除 .direct 模式）。N1 已加 Settings 橙色 reminder。
- Firebase SDK 在 Xcode 工程里**仍未接入**：需手动 Add Package Dependency + GoogleService-Info.plist + Enable Auth/Firestore in console + Sign In with Apple capability（详见 docs/plans/2026-03-28-backend-integration.md Task 3）
- syncFromFirestore 的 messages 同步是单向的：远端写一次（saveRecord 时），多端读时通过 messagesJSON blob backfill。同一 record 在不同设备产生新 messages 不会合并 —— 设计上一局游戏只在一端进行，不是并发问题

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
