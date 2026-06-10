import SwiftUI

struct GameView: View {

    @State private var vm: GameViewModel
    @State private var recordStore: GameRecordStore

    /// Optional; if nil the "生成 AI 复盘" button is hidden (proxy not configured
    /// or user not signed in).
    let reviewConfig: ReviewService.Config?
    /// Optional "play another puzzle" hook. When non-nil the answer sheet
    /// shows a 下一题 button; the parent decides what "next" means (random
    /// unplayed from the same list) and swaps its selection binding, which
    /// rebuilds this view via .id(puzzle.id). nil = no button (e.g. the
    /// multiplayer puzzle picker context).
    let onPlayNext: (() -> Void)?

    @FocusState private var inputFocused: Bool

    // iOS-only size-class adapter. macOS doesn't expose horizontalSizeClass
    // (it doesn't have the concept — windows can be any width but there's
    // no "compact" classification). On iPad we're always .regular and use
    // the two-column layout same as macOS. On iPhone (.compact) we pin a
    // collapsible scenario card above the chat and fold stats/actions
    // behind a toolbar button → sheet.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showInfoSheet = false
    @State private var scenarioExpanded = true
    private var isCompact: Bool { hSize == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    init(puzzle: Puzzle, claudeConfig: ClaudeService.Config, recordStore: GameRecordStore, reviewConfig: ReviewService.Config? = nil, isPublicPuzzle: Bool = false, onPlayNext: (() -> Void)? = nil) {
        _vm = State(wrappedValue: GameViewModel(puzzle: puzzle, claudeConfig: claudeConfig, recordStore: recordStore, isPublicPuzzle: isPublicPuzzle))
        _recordStore = State(wrappedValue: recordStore)
        self.reviewConfig = reviewConfig
        self.onPlayNext = onPlayNext
    }

    var body: some View {
        layoutForSizeClass
            .navigationTitle(vm.puzzle.title)
            .inlineNavTitleOnIOS()
            #if os(macOS)
            // macOS has a dedicated subtitle line below the title. iOS
            // surfaces the question count in the info sheet instead (and
            // inline in the regular-class right-hand pane).
            .navigationSubtitle("\(vm.questionCount) 问")
            #endif
            #if os(iOS)
            .toolbar {
                if isCompact {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showInfoSheet = true
                        } label: {
                            Label("信息", systemImage: "info.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $showInfoSheet) {
                NavigationStack {
                    ScrollView { infoPane.padding(.bottom, 12) }
                        .navigationTitle("汤面 · \(vm.questionCount) 问")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showInfoSheet = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            #endif
            .sheet(isPresented: $vm.showAnswer) { answerSheet }
            .alert("请求失败", isPresented: Binding(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
            )) {
                Button("好") { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .onAppear {
                inputFocused = true
                vm.loadPastReview()          // deferred CoreData fetch — see GameViewModel
                vm.restoreSessionIfNeeded()  // resume an interrupted game, if any
            }
    }

    /// Switches between the macOS / iPad two-column layout and the iPhone
    /// single-column layout. iPhone pins the scenario above the chat
    /// (lateral-thinking players re-read it constantly — burying it in the
    /// info sheet forced a modal round-trip per glance) and keeps
    /// stats/actions behind the toolbar ℹ️ button.
    @ViewBuilder
    private var layoutForSizeClass: some View {
        if isCompact {
            VStack(spacing: 0) {
                #if os(iOS)
                scenarioPin
                Divider()
                #endif
                chatPane
            }
        } else {
            // HStack (not HSplitView): HSplitView is an interactive
            // resizable splitter that fights NavigationSplitView's sidebar-
            // toggle animation, causing the toggle to freeze mid-transition.
            // Since both columns here have fixed/min-width constraints
            // anyway, the draggable divider added nothing.
            HStack(spacing: 0) {
                chatPane
                    .frame(minWidth: 460, maxWidth: .infinity)
                Divider()
                infoPane
                    .frame(width: 260)
                    .background(.regularMaterial)
            }
        }
    }

    // MARK: - Scenario pin (iPhone)

    #if os(iOS)
    /// Collapsible scenario card pinned above the chat on compact width.
    /// Defaults to expanded; tapping the header collapses it to one line
    /// to reclaim space once the player has internalized the setup.
    private var scenarioPin: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    scenarioExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("汤面", systemImage: "doc.text.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(scenarioExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(vm.puzzle.scenario)
                .font(.callout)
                .lineSpacing(4)
                .lineLimit(scenarioExpanded ? nil : 1)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.cardBackground)
    }
    #endif

    // MARK: - Chat pane

    private var chatPane: some View {
        VStack(spacing: 0) {
            messageList
            if vm.isGameWon { winBanner }
            Divider()
            inputBar
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    if vm.isLoading {
                        TypingIndicator()
                    }
                }
                .padding(16)
            }
            .onChange(of: vm.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if let lastId = vm.messages.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Two input strategies:
            //
            // macOS — TextEditor: multi-line editing with ↩ = newline and
            //   ⌘↩ = send (desktop chat convention; the placeholder
            //   advertises the shortcut).
            //
            // iOS — TextField(axis: .vertical): grows up to 4 lines, and
            //   the software keyboard's return key becomes a Send action
            //   (submitLabel). TextEditor can't do this — onKeyPress only
            //   fires for hardware keyboards, which left soft-keyboard
            //   users with no way to send except the paperplane.
            Group {
                #if os(iOS)
                TextField(
                    vm.isGameWon ? "谜题已解开" : "提问或陈述…",
                    text: $vm.inputText,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .font(.body)
                .focused($inputFocused)
                .disabled(vm.isGameWon)
                .submitLabel(.send)
                .onSubmit { vm.send() }
                #else
                ZStack(alignment: .topLeading) {
                    if vm.inputText.isEmpty {
                        Text(vm.isGameWon ? "谜题已解开" : "提问或陈述… (⌘↩ 发送)")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $vm.inputText)
                        .font(.body)
                        .frame(minHeight: 38, maxHeight: 100)
                        .scrollContentBackground(.hidden)
                        .focused($inputFocused)
                        .disabled(vm.isGameWon)
                        .onKeyPress(.return, phases: .down) { press in
                            // ⌘↩ 发送，普通 ↩ 换行
                            if press.modifiers.contains(.command) {
                                vm.send()
                                return .handled
                            }
                            return .ignored
                        }
                }
                #endif
            }
            .padding(8)
            // Cross-platform "text editor background" color. NSColor.textBackgroundColor
            // and UIColor.systemBackground both render as a clean panel surface that
            // adapts to dark mode; SwiftUI's Color(.textBackgroundColor) only resolves
            // on macOS. .regularMaterial is the closest cross-platform equivalent —
            // it's a thin material that picks up the parent's tint cleanly.
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )

            Button(action: vm.send) {
                // Swap the send glyph for a small spinner while the model is
                // thinking — pairs with TypingIndicator's caption to make the
                // wait feel busy instead of frozen.
                if vm.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var canSend: Bool {
        !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !vm.isLoading && !vm.isGameWon
    }

    // MARK: - Info pane

    private var infoPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 汤面
            VStack(alignment: .leading, spacing: 8) {
                Label("汤面", systemImage: "doc.text.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(vm.puzzle.scenario)
                    .font(.callout)
                    .lineSpacing(5)
                    .textSelection(.enabled)
            }
            .padding(16)

            Divider()

            // 游戏统计
            VStack(alignment: .leading, spacing: 12) {
                Label("本局统计", systemImage: "chart.bar.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                statRow(label: "已提问", value: "\(vm.questionCount) 次")
                statRow(label: "难度", value: vm.puzzle.difficulty.rawValue)
                statRow(label: "出题者", value: vm.puzzle.author)
                historicalStatsSection
            }
            .padding(16)

            Divider()

            // 快捷操作
            VStack(alignment: .leading, spacing: 8) {
                Label("操作", systemImage: "ellipsis.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if vm.isGameWon {
                    Button {
                        vm.showAnswer = true
                    } label: {
                        Label("查看汤底", systemImage: "eye.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if !vm.isGameWon {
                    Button(role: .destructive) {
                        vm.showGiveUpConfirm = true
                    } label: {
                        // "放弃并看汤底" — the old "放弃查看答案" parsed
                        // ambiguously as "放弃【查看答案】" (decline to view).
                        Label("放弃并看汤底", systemImage: "flag.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .confirmationDialog("确认放弃？", isPresented: $vm.showGiveUpConfirm, titleVisibility: .visible) {
                        Button("放弃并查看汤底", role: .destructive) { vm.giveUp() }
                        Button("继续游戏", role: .cancel) {}
                    } message: {
                        Text("放弃将记录为未完成，游戏结束后可查看汤底。")
                    }
                }

                // Share is always available — a stumped player bragging
                // "this one beat me, can you solve it?" is just as viral
                // as a win. The share text never includes the answer.
                ShareLink(item: shareText) {
                    Label("分享题目", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(16)

            Spacer()
        }
    }

    @ViewBuilder
    private var historicalStatsSection: some View {
        let _ = recordStore.savedRecordCount  // establishes @Observable dependency for auto-refresh
        let total = recordStore.playCount(for: vm.puzzle.id)
        if total > 0 {
            let rate = recordStore.winRate(for: vm.puzzle.id)
            Divider()
            statRow(label: "历史游玩", value: "\(total) 次")
            statRow(label: "胜率",     value: String(format: "%.0f%%", rate * 100))
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
        }
    }

    // MARK: - Win banner

    private var winBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "party.popper.fill")
                .foregroundStyle(.teal)
            Text("恭喜！你还原了真相")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.teal)
            Spacer()
            Button("查看汤底") { vm.showAnswer = true }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.teal)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.teal.opacity(0.1))
    }

    // MARK: - Answer sheet

    /// Share copy for the current game. Win → brag with the question
    /// count; loss → "this one beat me" challenge. Neither leaks the
    /// answer — just the title and scenario hook.
    private var shareText: String {
        let header = vm.isGameWon
            ? "我在《海龟汤》用 \(vm.questionCount) 个问题解开了「\(vm.puzzle.title)」！你能用更少的问题吗？"
            : "这道海龟汤把我难住了：「\(vm.puzzle.title)」，你能解开吗？"
        return "\(header)\n\n汤面：\(vm.puzzle.scenario)"
    }

    private var answerSheet: some View {
        // Outer ScrollView so the sheet contents — which can grow tall
        // once an AI review with 3-5 moments + summary + tip + the
        // existing fixed-height answer block lands — stay reachable on
        // narrow iPhone screens.
        //
        // iOS wraps in NavigationStack so 完成 lives in the toolbar — at
        // the end of a long review the close affordance shouldn't require
        // scrolling to the bottom. macOS keeps the inline footer button
        // (sheet toolbars are unusual there).
        let core = ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if os(macOS)
                Text("真相大白")
                    .font(.title2.weight(.semibold))
                Divider()
                #endif

                // 统计
                HStack(spacing: 32) {
                    answerStat(label: "提问次数", value: "\(vm.questionCount)")
                    answerStat(label: "难度", value: vm.puzzle.difficulty.rawValue)
                    answerStat(label: "出题者", value: vm.puzzle.author)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Label("汤底（完整真相）", systemImage: "lightbulb.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(vm.puzzle.answer)
                        .font(.body)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // AI 复盘 section — only available when a proxy is configured.
                if reviewConfig != nil {
                    Divider()
                    reviewSection
                }

                Divider()

                // Game-loop CTAs. 下一题 keeps the session going (the #1
                // retention lever — without it every finished game dead-ends
                // back at the list); ShareLink turns wins into invitations.
                VStack(spacing: 10) {
                    if let onPlayNext {
                        Button {
                            vm.showAnswer = false
                            onPlayNext()
                        } label: {
                            Label("下一题", systemImage: "arrow.right.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    HStack {
                        ShareLink(item: shareText) {
                            Label(vm.isGameWon ? "分享战绩" : "分享这道题", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        #if os(macOS)
                        // Prominent only when it's the sole CTA — with a
                        // 下一题 button above, 完成 takes the back seat.
                        // (if/else, not a ternary: .borderedProminent and
                        // .bordered are distinct ButtonStyle types.)
                        if onPlayNext == nil {
                            Button("完成") { vm.showAnswer = false }
                                .keyboardShortcut(.defaultAction)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("完成") { vm.showAnswer = false }
                                .keyboardShortcut(.defaultAction)
                                .buttonStyle(.bordered)
                        }
                        #endif
                    }
                }
            }
            .padding(24)
        }

        #if os(macOS)
        // macOS sheets don't size to fit content — give it an explicit
        // width. iOS gets the system sheet width, with the content
        // free-flowing inside scrollable bounds.
        return core.frame(width: 480)
        #else
        return NavigationStack {
            core
                .navigationTitle("真相大白")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { vm.showAnswer = false }
                    }
                }
        }
        #endif
    }

    // MARK: - AI review

    @ViewBuilder
    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI 复盘", systemImage: "sparkles")
                .font(.headline)

            // Priority order matters here. Each branch represents a state
            // that should never be masked by a less-current one:
            //   1. aiReview — freshly generated this game; always wins
            //   2. isGeneratingReview — stream in flight; show progress
            //   3. reviewError — most recent attempt failed; offer retry.
            //      Comes BEFORE pastReview so a failed regen doesn't
            //      silently snap back to the cached one.
            //   4. pastReview — cache hit from a prior play
            //   5. default "生成 AI 复盘"
            if let review = vm.aiReview {
                renderedReview(review)
            } else if vm.isGeneratingReview {
                reviewProgressPane
            } else if let err = vm.reviewError {
                reviewErrorBox(err)
            } else if let past = vm.pastReview {
                pastReviewSection(past)
            } else {
                Button {
                    guard let cfg = reviewConfig else { return }
                    vm.startReviewGeneration(config: cfg)
                } label: {
                    Label("生成 AI 复盘", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func renderedReview(_ review: GameReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(review.summary)
                .font(.body.weight(.medium))

            ForEach(review.keyMoments) { moment in
                HStack(alignment: .top, spacing: 8) {
                    momentBadge(moment.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("第 \(moment.turn) 轮")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(moment.comment)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.orange)
                Text(review.tip)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func momentBadge(_ kind: GameReview.Moment.Kind) -> some View {
        let (bg, fg, sym) = momentStyle(kind)
        return Label(kind.label, systemImage: sym)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(Capsule())
    }

    /// Error + retry card. Pulled out so the answer-sheet conditional stays
    /// readable now that there are five mutually-exclusive review states.
    private func reviewErrorBox(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                guard let cfg = reviewConfig else { return }
                vm.reviewError = nil
                vm.startReviewGeneration(config: cfg)
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Render a previously-cached review with a small caption explaining
    /// where it came from and a "重新生成" affordance for the current game's
    /// transcript. Same renderedReview layout — the only difference from a
    /// freshly-generated review is the label at the top.
    @ViewBuilder
    private func pastReviewSection(_ review: GameReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("上次此题的复盘")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard let cfg = reviewConfig else { return }
                    vm.startReviewGeneration(config: cfg)
                } label: {
                    Label("基于本局重新生成", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(reviewConfig == nil)
            }
            renderedReview(review)
        }
    }

    /// Progress checklist shown while a review is streaming in. summary and
    /// tip are the only fields the proxy emits progress for; key_moments[]
    /// arrives in the complete event (its row carries a pendingNote that
    /// explains the wait). Layout lives in StreamingChecklist.swift.
    private var reviewProgressPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在复盘…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Button("取消", role: .cancel) {
                    vm.cancelReviewGeneration()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            StreamingChecklist(
                rows: ChecklistSchemas.review,
                streamedFields: vm.reviewProgress
            )
        }
    }

    private func momentStyle(_ kind: GameReview.Moment.Kind) -> (bg: Color, fg: Color, symbol: String) {
        switch kind {
        case .goodQuestion:   return (.green.opacity(0.15), .green,  "checkmark.circle")
        case .wrongDirection: return (.red.opacity(0.15),   .red,    "arrow.uturn.left")
        case .breakthrough:   return (.teal.opacity(0.15),  .teal,   "sparkle")
        case .gotStuck:       return (.orange.opacity(0.15),.orange, "pause.circle")
        }
    }

    private func answerStat(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
