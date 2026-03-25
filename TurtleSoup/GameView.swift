import SwiftUI

struct GameView: View {

    @State private var vm: GameViewModel
    @State private var recordStore: GameRecordStore

    @FocusState private var inputFocused: Bool

    init(puzzle: Puzzle, apiKey: String, recordStore: GameRecordStore) {
        _vm = State(wrappedValue: GameViewModel(puzzle: puzzle, apiKey: apiKey, recordStore: recordStore))
        _recordStore = State(wrappedValue: recordStore)
    }

    var body: some View {
        HSplitView {
            // 左：对话主区
            chatPane
                .frame(minWidth: 460)

            // 右：汤面 + 控制面板
            infoPane
                .frame(width: 260)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle(vm.puzzle.title)
        .navigationSubtitle("\(vm.questionCount) 问")
        .sheet(isPresented: $vm.showAnswer) { answerSheet }
        .alert("请求失败", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("好") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onAppear { inputFocused = true }
    }

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
            // macOS：用 TextEditor 支持多行
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
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )

            Button(action: vm.send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
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

                Button {
                    // TODO: 分享功能
                } label: {
                    Label("分享题目", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!vm.isGameWon)
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

    private var answerSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("真相大白")
                .font(.title2.weight(.semibold))

            Divider()

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
                ScrollView {
                    Text(vm.puzzle.answer)
                        .font(.body)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }

            HStack {
                Spacer()
                Button("完成") { vm.showAnswer = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func answerStat(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
