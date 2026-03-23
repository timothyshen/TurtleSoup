import SwiftUI

struct PuzzleEditorView: View {

    @Binding var editingPuzzle: Puzzle?
    var store: PuzzleStore

    // Form state
    @State private var title: String = ""
    @State private var difficulty: Puzzle.Difficulty = .medium
    @State private var scenario: String = ""
    @State private var answer: String = ""
    @State private var hint: String = ""
    @State private var author: String = ""

    // The puzzle being edited (non-nil means edit mode)
    @State private var originalPuzzle: Puzzle? = nil

    // Validation errors
    @State private var titleError: String? = nil
    @State private var scenarioError: String? = nil
    @State private var answerError: String? = nil
    @State private var hintError: String? = nil
    @State private var authorError: String? = nil

    // Delete confirmation
    @State private var showDeleteAlert = false

    var isEditMode: Bool { originalPuzzle != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 标题
                fieldSection(label: "题目标题", required: true) {
                    TextField("请输入标题（最多 40 字）", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .overlay(fieldBorder(hasError: titleError != nil))
                        .onChange(of: title) { validateTitle() }
                    if let err = titleError {
                        errorText(err)
                    }
                }

                // 难度
                fieldSection(label: "难度", required: true) {
                    Picker("难度", selection: $difficulty) {
                        ForEach(Puzzle.Difficulty.allCases, id: \.self) { d in
                            Text(d.rawValue).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // 汤面
                fieldSection(label: "汤面（场景描述）", required: true) {
                    TextEditor(text: $scenario)
                        .font(.body)
                        .frame(minHeight: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(scenarioError != nil ? Color.red : Color.secondary.opacity(0.3), lineWidth: scenarioError != nil ? 1.5 : 0.5)
                        )
                        .onChange(of: scenario) { validateScenario() }
                    HStack {
                        if let err = scenarioError {
                            errorText(err)
                        }
                        Spacer()
                        Text("\(scenario.count)/500")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // 汤底
                fieldSection(label: "汤底（答案）", required: true) {
                    TextEditor(text: $answer)
                        .font(.body)
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(answerError != nil ? Color.red : Color.secondary.opacity(0.3), lineWidth: answerError != nil ? 1.5 : 0.5)
                        )
                        .onChange(of: answer) { validateAnswer() }
                    HStack {
                        if let err = answerError {
                            errorText(err)
                        }
                        Spacer()
                        Text("\(answer.count)/2000")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // 提示
                fieldSection(label: "提示", required: false) {
                    TextField("选填，最多 100 字", text: $hint)
                        .textFieldStyle(.roundedBorder)
                        .overlay(fieldBorder(hasError: hintError != nil))
                        .onChange(of: hint) { validateHint() }
                    if let err = hintError {
                        errorText(err)
                    }
                }

                // 作者署名
                fieldSection(label: "作者署名", required: false) {
                    TextField("选填，最多 20 字", text: $author)
                        .textFieldStyle(.roundedBorder)
                        .overlay(fieldBorder(hasError: authorError != nil))
                        .onChange(of: author) { validateAuthor() }
                    if let err = authorError {
                        errorText(err)
                    }
                }

                // 按钮区
                HStack(spacing: 12) {
                    if isEditMode {
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Text("删除")
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button("保存") {
                        savePuzzle()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
        .navigationTitle(isEditMode ? "编辑题目" : "新建题目")
        .onAppear { loadPuzzle(editingPuzzle) }
        .onChange(of: editingPuzzle) { loadPuzzle(editingPuzzle) }
        .alert("确认删除", isPresented: $showDeleteAlert) {
            Button("删除", role: .destructive) {
                if let puzzle = originalPuzzle {
                    store.delete(puzzle)
                    editingPuzzle = nil
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除「\(originalPuzzle?.title ?? "")」吗？此操作无法撤销。")
        }
    }

    // MARK: - Load

    private func loadPuzzle(_ puzzle: Puzzle?) {
        originalPuzzle = puzzle
        title = puzzle?.title ?? ""
        difficulty = puzzle?.difficulty ?? .medium
        scenario = puzzle?.scenario ?? ""
        answer = puzzle?.answer ?? ""
        hint = puzzle?.hint ?? ""
        author = puzzle?.author ?? ""
        // Clear errors
        titleError = nil
        scenarioError = nil
        answerError = nil
        hintError = nil
        authorError = nil
    }

    // MARK: - Save

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !scenario.trimmingCharacters(in: .whitespaces).isEmpty &&
        !answer.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func savePuzzle() {
        validateAll()
        guard titleError == nil, scenarioError == nil, answerError == nil,
              hintError == nil, authorError == nil else { return }

        let puzzle = Puzzle(
            id: originalPuzzle?.id ?? UUID(),
            title: title.trimmingCharacters(in: .whitespaces),
            difficulty: difficulty,
            scenario: scenario.trimmingCharacters(in: .whitespaces),
            answer: answer.trimmingCharacters(in: .whitespaces),
            hint: hint.trimmingCharacters(in: .whitespaces).isEmpty ? nil : hint.trimmingCharacters(in: .whitespaces),
            author: author.trimmingCharacters(in: .whitespaces).isEmpty ? "匿名" : author.trimmingCharacters(in: .whitespaces),
            playCount: originalPuzzle?.playCount ?? 0
        )
        store.save(puzzle)
        originalPuzzle = puzzle
        editingPuzzle = puzzle
    }

    // MARK: - Validation

    private func validateAll() {
        validateTitle()
        validateScenario()
        validateAnswer()
        validateHint()
        validateAuthor()
    }

    private func validateTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            titleError = "题目标题不能为空"
        } else if trimmed.count > 40 {
            titleError = "标题最多 40 字（当前 \(trimmed.count) 字）"
        } else {
            titleError = nil
        }
    }

    private func validateScenario() {
        let trimmed = scenario.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            scenarioError = "汤面不能为空"
        } else if trimmed.count < 20 {
            scenarioError = "汤面至少 20 字（当前 \(trimmed.count) 字）"
        } else if trimmed.count > 500 {
            scenarioError = "汤面最多 500 字（当前 \(trimmed.count) 字）"
        } else {
            scenarioError = nil
        }
    }

    private func validateAnswer() {
        let trimmed = answer.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            answerError = "汤底不能为空"
        } else if trimmed.count < 50 {
            answerError = "汤底至少 50 字（当前 \(trimmed.count) 字）"
        } else if trimmed.count > 2000 {
            answerError = "汤底最多 2000 字（当前 \(trimmed.count) 字）"
        } else {
            answerError = nil
        }
    }

    private func validateHint() {
        let trimmed = hint.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 100 {
            hintError = "提示最多 100 字（当前 \(trimmed.count) 字）"
        } else {
            hintError = nil
        }
    }

    private func validateAuthor() {
        let trimmed = author.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 20 {
            authorError = "作者署名最多 20 字（当前 \(trimmed.count) 字）"
        } else {
            authorError = nil
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func fieldSection<Content: View>(label: String, required: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                if required {
                    Text("*")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            content()
        }
    }

    private func fieldBorder(hasError: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(hasError ? Color.red : Color.clear, lineWidth: 1.5)
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
    }
}
