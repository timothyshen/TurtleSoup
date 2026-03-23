import SwiftUI

struct GameView: View {

    @StateObject private var vm: GameViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    init(puzzle: Puzzle, apiKey: String) {
        _vm = StateObject(wrappedValue: GameViewModel(puzzle: puzzle, apiKey: apiKey))
    }

    var body: some View {
        VStack(spacing: 0) {
            scenarioCard
            Divider()
            messageList
            if vm.isGameWon { winBanner }
            inputBar
        }
        .navigationTitle(vm.puzzle.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { questionCounter }
        .sheet(isPresented: $vm.showAnswer) { answerSheet }
        .alert("错误", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("好") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    // MARK: - Scenario card

    private var scenarioCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("汤面", systemImage: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(vm.puzzle.scenario)
                .font(.subheadline)
                .lineSpacing(4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    if vm.isLoading {
                        TypingIndicator()
                            .id("typing")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: vm.messages.count) { _ in
                withAnimation { proxy.scrollTo(vm.messages.last?.id ?? "typing") }
            }
            .onChange(of: vm.isLoading) { loading in
                if loading { withAnimation { proxy.scrollTo("typing") } }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(vm.isGameWon ? "谜题已解开" : "提问或陈述…", text: $vm.inputText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .focused($inputFocused)
                .disabled(vm.isGameWon)
                .onSubmit { vm.send() }

            Button(action: vm.send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !vm.isLoading && !vm.isGameWon
    }

    // MARK: - Win banner

    private var winBanner: some View {
        HStack {
            Image(systemName: "party.popper.fill")
            Text("恭喜！你解开了谜题！")
                .fontWeight(.medium)
            Spacer()
            Button("查看答案") { vm.showAnswer = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(14)
        .background(Color.teal.opacity(0.15))
        .foregroundStyle(Color.teal)
    }

    // MARK: - Answer sheet

    private var answerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statRow
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Label("汤底（完整真相）", systemImage: "eye.fill")
                            .font(.headline)
                        Text(vm.puzzle.answer)
                            .font(.body)
                            .lineSpacing(6)
                            .foregroundStyle(.primary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("揭晓真相")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { vm.showAnswer = false }
                }
            }
        }
    }

    private var statRow: some View {
        HStack(spacing: 24) {
            statCard(label: "提问次数", value: "\(vm.questionCount)")
            Divider().frame(height: 36)
            statCard(label: "难度", value: vm.puzzle.difficulty.rawValue)
            Divider().frame(height: 36)
            statCard(label: "出题者", value: vm.puzzle.author)
        }
        .frame(maxWidth: .infinity)
    }

    private func statCard(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3).fontWeight(.semibold)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Toolbar

    private var questionCounter: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Label("\(vm.questionCount) 问", systemImage: "questionmark.bubble")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
