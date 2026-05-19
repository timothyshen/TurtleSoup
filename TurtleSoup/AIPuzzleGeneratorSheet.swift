import SwiftUI

/// Sheet for AI-assisted puzzle drafting.
///
/// User types a one-line idea (+ optional difficulty), hits 生成, sees a preview
/// of the AI-drafted puzzle, then 应用 to fill the editor fields. The user always
/// has the final say — nothing is auto-saved.
struct AIPuzzleGeneratorSheet: View {

    /// Pre-built generator config. nil = proxy not configured; sheet shows
    /// guidance instead of the input form.
    let config: PuzzleGenerationService.Config?

    /// Called with the user-approved puzzle when they tap 应用.
    /// Parent fills its editor fields from this and dismisses the sheet.
    let onApply: (Puzzle) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var idea: String = ""
    @State private var difficulty: Puzzle.Difficulty = .medium
    @State private var usePreferredDifficulty: Bool = false

    @State private var isGenerating: Bool = false
    @State private var generated: Puzzle? = nil
    @State private var errorMessage: String? = nil
    /// Fields that have streamed in so far, in arrival order. Drives the
    /// progress checklist UI shown while `isGenerating` is true.
    @State private var streamedFields: [(field: String, value: String)] = []
    /// Handle to the in-flight generation. Held so dismissing the sheet
    /// (X button, Esc, or 取消) actually cancels the URLSession task
    /// rather than orphaning it.
    @State private var streamTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if config == nil {
                proxyMissingNotice
            } else if let puzzle = generated {
                previewPane(puzzle)
            } else if isGenerating {
                progressPane
            } else {
                inputForm
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(24)
        .frame(width: 560, height: 540)
        .onDisappear { cancelStream() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("AI 辅助出题", systemImage: "sparkles")
                .font(.title3.weight(.semibold))
            Text("写一句创意，Claude 帮你扩写成完整海龟汤。生成后你可随意修改。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var inputForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("创意 / 关键词").font(.subheadline.weight(.medium))
                TextEditor(text: $idea)
                    .frame(minHeight: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
                Text("例：「一个考古学家在沙漠里挖出一台还在响的收音机」")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("指定目标难度", isOn: $usePreferredDifficulty)
                if usePreferredDifficulty {
                    Picker("难度", selection: $difficulty) {
                        ForEach(Puzzle.Difficulty.allCases, id: \.self) { d in
                            Text(d.rawValue).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            if let err = errorMessage {
                // Error state. Show the message + a retry button so the user
                // doesn't have to figure out that the "生成" footer button
                // also retries (it does, but discoverability is poor when
                // the failure is the only thing on screen).
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
                        startStream()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(config == nil || idea.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func previewPane(_ puzzle: Puzzle) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                fieldRow("标题", puzzle.title)
                fieldRow("难度", puzzle.difficulty.rawValue)
                fieldRow("汤面", puzzle.scenario)
                fieldRow("汤底", puzzle.answer)
                if let hint = puzzle.hint, !hint.isEmpty {
                    fieldRow("提示", hint)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func fieldRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Live progress pane shown while the stream is filling fields.
    /// Schema + row rendering live in StreamingChecklist so the layout
    /// can be previewed in isolation and reused by the review section.
    private var progressPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在构思题目…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) {
                    cancelStream()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            StreamingChecklist(
                rows: ChecklistSchemas.puzzle,
                streamedFields: streamedFields
            )

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var proxyMissingNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("尚未配置代理", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("AI 出题需要先在「设置 → Claude API → 代理 Base URL」里填好 Vercel 部署地址，并登录账号。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            if generated != nil {
                Button("重新生成") {
                    generated = nil
                    errorMessage = nil
                }
                .disabled(isGenerating)

                Button("应用到编辑器") {
                    if let p = generated { onApply(p) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    startStream()
                } label: {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("生成")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(config == nil || isGenerating || idea.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Actions

    /// Kick off generation in a cancellable Task. Stored on `streamTask`
    /// so dismiss-mid-stream (X button, cmd-W, etc) actually aborts the
    /// upstream URLSession call rather than letting it run to completion
    /// against a dead UI.
    private func startStream() {
        guard let config else { return }
        cancelStream()  // belt + suspenders: defensively clear any prior task
        streamTask = Task { await runGeneration(config: config) }
    }

    private func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        isGenerating = false
        // Keep streamedFields visible so the user sees what was almost
        // generated; clearing them would feel like the cancel "won" too
        // hard. They get reset on the next startStream().
    }

    private func runGeneration(config: PuzzleGenerationService.Config) async {
        isGenerating = true
        errorMessage = nil
        streamedFields = []
        defer {
            isGenerating = false
            streamTask = nil
        }

        do {
            let service = PuzzleGenerationService(config: config)
            let stream = service.generateStream(
                idea: idea.trimmingCharacters(in: .whitespacesAndNewlines),
                difficulty: usePreferredDifficulty ? difficulty : nil
            )
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .progress(let field, let value):
                    // Don't overwrite an already-streamed field if the proxy
                    // somehow re-emits — first close wins.
                    if !streamedFields.contains(where: { $0.field == field }) {
                        streamedFields.append((field: field, value: value))
                    }
                case .complete(let puzzle):
                    generated = puzzle
                }
            }
        } catch is CancellationError {
            // User-initiated cancel; cancelStream already reset isGenerating.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
