import SwiftUI

struct PuzzleListView: View {

    @AppStorage("claude_api_key") private var apiKey: String = ""
    @State private var showKeyInput = false
    @State private var recordStore = GameRecordStore()

    private let puzzles = Puzzle.builtIn

    var body: some View {
        NavigationStack {
            Group {
                if apiKey.isEmpty {
                    apiKeyPrompt
                } else {
                    puzzleGrid
                }
            }
            .navigationTitle("🐢 海龟汤")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showKeyInput = true
                    } label: {
                        Image(systemName: "key")
                    }
                }
            }
            .sheet(isPresented: $showKeyInput) {
                APIKeySheet(apiKey: $apiKey)
            }
        }
    }

    private var puzzleGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(puzzles) { puzzle in
                    NavigationLink {
                        GameView(puzzle: puzzle, apiKey: apiKey, recordStore: recordStore)
                    } label: {
                        PuzzleCard(puzzle: puzzle)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private var apiKeyPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("请先配置 Claude API Key")
                .font(.headline)
            Text("Key 仅存于本机 UserDefaults，不上传任何服务器")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("配置 API Key") { showKeyInput = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

// MARK: - Puzzle card

struct PuzzleCard: View {
    let puzzle: Puzzle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(puzzle.difficulty.rawValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(difficultyColor.opacity(0.15))
                    .foregroundStyle(difficultyColor)
                    .clipShape(Capsule())
                Spacer()
            }
            Text(puzzle.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(puzzle.scenario)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .lineSpacing(2)
            Spacer()
            Text("by \(puzzle.author)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var difficultyColor: Color {
        switch puzzle.difficulty {
        case .easy:   return .teal
        case .medium: return .orange
        case .hard:   return .red
        }
    }
}

// MARK: - API key sheet

struct APIKeySheet: View {
    @Binding var apiKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $draft)
                        .autocorrectionDisabled()
                } header: {
                    Text("Claude API Key")
                } footer: {
                    Text("在 console.anthropic.com 获取。Key 仅存储在本机，不会上传。")
                }
            }
            .navigationTitle("配置 API Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        apiKey = draft
                        dismiss()
                    }
                    .disabled(draft.isEmpty)
                }
            }
            .onAppear { draft = apiKey }
        }
    }
}
