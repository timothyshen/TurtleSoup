import SwiftUI

// History viewer for past game sessions.
//
// Two layers:
//   HistorySidebarList — list of records, used inside SidebarView.
//   HistoryDetailView  — full record render: transcript bubbles + AI review.
//
// Records are pulled via GameRecordStore.allRecords(). We re-read on
// .task(id:) tied to savedRecordCount so new wins / give-ups / sync-pull
// backfills refresh the list without needing a NotificationCenter dance.

struct HistorySidebarList: View {

    @Bindable var recordStore: GameRecordStore
    @Binding var selectedRecord: GameRecord?

    @State private var records: [GameRecord] = []
    @State private var searchText: String = ""

    var body: some View {
        Group {
            if records.isEmpty {
                emptyState
            } else {
                List(filtered, selection: $selectedRecord) { record in
                    HistoryRow(record: record).tag(record)
                }
                .listStyle(.sidebar)
                .searchable(text: $searchText, placement: .sidebar, prompt: "搜索标题")
            }
        }
        .task(id: recordStore.savedRecordCount) {
            // Re-fetch when a new record is written or backfilled via sync.
            // savedRecordCount is bumped by saveRecord, updateAIReview, and
            // dedup-hit backfill — covers every state change we care about.
            records = recordStore.allRecords()
        }
    }

    private var filtered: [GameRecord] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return records }
        return records.filter { $0.puzzleTitle.localizedCaseInsensitiveContains(q) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("还没有历史对局")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("玩完一局或同步登录后会出现在这里")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// One row in the history list. Compact — title, win/lose icon, date,
/// question count. Detail pane shows the full transcript on selection.
private struct HistoryRow: View {

    let record: GameRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.isWon ? "checkmark.circle.fill" : "flag.fill")
                .foregroundStyle(record.isWon ? .teal : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.puzzleTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.dateFormatter.string(from: record.startedAt))
                    Text("·")
                    Text("\(record.questionCount) 问")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

// MARK: - Overview (shown in detail pane when no record is selected)

/// Aggregate stats across all recorded games. Lives in the detail pane
/// when no specific record is selected so the user gets a snapshot the
/// moment they switch to the history tab. Recomputes lazily from
/// `recordStore.allRecords()` keyed on `savedRecordCount`.
struct HistoryOverviewView: View {

    @Bindable var recordStore: GameRecordStore
    @State private var records: [GameRecord] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("全局统计", systemImage: "chart.bar.xaxis")
                    .font(.title2.weight(.semibold))

                if records.isEmpty {
                    Text("还没有记录的对局。先玩一局看看吧。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    statsGrid
                    recentWinsRow
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("历史")
        .task(id: recordStore.savedRecordCount) {
            records = recordStore.allRecords()
        }
    }

    // MARK: - Stats grid

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
                  alignment: .leading, spacing: 12) {
            statCard(label: "总对局",
                     value: "\(records.count)",
                     subtitle: "次")
            statCard(label: "胜率",
                     value: String(format: "%.0f%%", overallWinRate * 100),
                     subtitle: "\(wonCount) / \(records.count)",
                     accent: .teal)
            statCard(label: "总提问数",
                     value: "\(totalQuestions)",
                     subtitle: "次")
            statCard(label: "平均用时",
                     value: averageDurationString,
                     subtitle: "每局")
            if let fastest = fastestWin {
                statCard(label: "最快通关",
                         value: durationString(fastest.endedAt.timeIntervalSince(fastest.startedAt)),
                         subtitle: fastest.puzzleTitle,
                         accent: .orange)
            }
            if let mostAsked = mostAsked {
                statCard(label: "提问最多",
                         value: "\(mostAsked.questionCount) 问",
                         subtitle: mostAsked.puzzleTitle)
            }
        }
    }

    private func statCard(label: String, value: String, subtitle: String,
                          accent: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Recent wins strip

    @ViewBuilder
    private var recentWinsRow: some View {
        let wins = records.filter { $0.isWon }.prefix(5)
        if !wins.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("最近五次通关")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(wins)) { record in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.teal)
                        Text(record.puzzleTitle)
                            .font(.callout)
                        Spacer()
                        Text("\(record.questionCount) 问 · \(durationString(record.endedAt.timeIntervalSince(record.startedAt)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Aggregates

    private var wonCount: Int        { records.filter { $0.isWon }.count }
    private var overallWinRate: Double {
        records.isEmpty ? 0 : Double(wonCount) / Double(records.count)
    }
    private var totalQuestions: Int  { records.reduce(0) { $0 + $1.questionCount } }
    private var averageDurationString: String {
        guard !records.isEmpty else { return "—" }
        let total = records.reduce(0.0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) }
        return durationString(total / Double(records.count))
    }
    private var fastestWin: GameRecord? {
        records.filter { $0.isWon }
            .min(by: {
                $0.endedAt.timeIntervalSince($0.startedAt) <
                $1.endedAt.timeIntervalSince($1.startedAt)
            })
    }
    private var mostAsked: GameRecord? {
        records.max(by: { $0.questionCount < $1.questionCount })
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let secs = Int(seconds)
        let m = secs / 60, s = secs % 60
        return m > 0 ? "\(m)分\(s)秒" : "\(s)秒"
    }
}

// MARK: - Detail

/// Full read-only render of a past game. The transcript is read from the
/// record's `messages` array (already-hydrated by GameRecordStore.allRecords),
/// not re-fetched. The AI review section shows the cached review if any,
/// or notes that none was generated. No "regenerate" affordance here — that
/// path only makes sense from the live answerSheet against the current game.
struct HistoryDetailView: View {

    let record: GameRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                transcriptSection
                if let review = record.aiReview {
                    Divider()
                    reviewSection(review)
                } else if !record.isWon {
                    Divider()
                    noReviewNotice
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(record.puzzleTitle)
        .navigationSubtitle(headerSubtitle)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 16) {
            statBlock(label: "结果",
                      value: record.isWon ? "解出" : "放弃",
                      color: record.isWon ? .teal : .secondary)
            statBlock(label: "提问", value: "\(record.questionCount) 次")
            statBlock(label: "用时", value: durationString)
        }
    }

    private var headerSubtitle: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: record.startedAt)
    }

    private var durationString: String {
        let secs = Int(record.endedAt.timeIntervalSince(record.startedAt))
        let m = secs / 60, s = secs % 60
        return m > 0 ? "\(m) 分 \(s) 秒" : "\(s) 秒"
    }

    private func statBlock(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var transcriptSection: some View {
        Label("对话历史", systemImage: "bubble.left.and.bubble.right.fill")
            .font(.headline)
        if record.messages.isEmpty {
            Text("对话历史在此设备上不可用——可能从其他设备同步过来但同步通道未携带 transcript（旧版本写入）。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                ForEach(record.messages) { msg in
                    MessageBubble(message: msg)
                }
            }
        }
    }

    @ViewBuilder
    private func reviewSection(_ review: GameReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI 复盘", systemImage: "sparkles")
                .font(.headline)
            Text(review.summary).font(.body.weight(.medium))

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
                Image(systemName: "lightbulb").foregroundStyle(.orange)
                Text(review.tip)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var noReviewNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("这局未生成 AI 复盘。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Moment badge (duplicated from GameView; small enough not to extract)

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

    private func momentStyle(_ kind: GameReview.Moment.Kind) -> (bg: Color, fg: Color, symbol: String) {
        switch kind {
        case .goodQuestion:   return (.green.opacity(0.15), .green,  "checkmark.circle")
        case .wrongDirection: return (.red.opacity(0.15),   .red,    "arrow.uturn.left")
        case .breakthrough:   return (.teal.opacity(0.15),  .teal,   "sparkle")
        case .gotStuck:       return (.orange.opacity(0.15),.orange, "pause.circle")
        }
    }
}

// MARK: - Previews

#Preview("HistoryDetail — won + review") {
    HistoryDetailView(record: GameRecord(
        id: UUID(),
        puzzleID: UUID(),
        puzzleTitle: "失踪的钢琴师",
        startedAt: Date().addingTimeInterval(-600),
        endedAt: Date(),
        isWon: true,
        questionCount: 8,
        messages: [
            Message(role: .system, text: "游戏开始"),
            Message(role: .user, text: "他活着吗？"),
            Message(role: .assistant, text: "无关", verdict: .irr),
            Message(role: .user, text: "他在弹的曲子有特别的意义吗？"),
            Message(role: .assistant, text: "对", verdict: .yes),
        ],
        aiReview: GameReview(
            summary: "你用 8 轮锁定了真相。",
            keyMoments: [
                .init(turn: 2, kind: .goodQuestion, comment: "「曲子的意义」是关键切入"),
                .init(turn: 5, kind: .breakthrough, comment: "想到隔音问题那一刻"),
            ],
            tip: "看到「同步」类描述时先想物理原因。"
        )
    ))
    .frame(width: 640, height: 600)
}

#Preview("HistoryOverview — empty store") {
    HistoryOverviewView(recordStore: GameRecordStore(pc: .test))
        .frame(width: 640, height: 500)
}

#Preview("HistoryDetail — give-up no review") {
    HistoryDetailView(record: GameRecord(
        id: UUID(),
        puzzleID: UUID(),
        puzzleTitle: "公园里的湿长椅",
        startedAt: Date().addingTimeInterval(-300),
        endedAt: Date(),
        isWon: false,
        questionCount: 3,
        messages: [
            Message(role: .user, text: "是下雨吗？"),
            Message(role: .assistant, text: "否", verdict: .no),
        ],
        aiReview: nil
    ))
    .frame(width: 640, height: 600)
}
